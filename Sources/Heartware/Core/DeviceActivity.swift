import Foundation
import CoreAudio
import CoreMediaIO

/// Who records from a microphone, who plays sound, whether a camera films: watched once for the whole app, for
/// Protection (the microphone or the camera turning on) and Boost (an app playing sound keeps its full speed).
/// The CoreAudio and CoreMediaIO listeners live on a queue of their own, never on the main thread: a burst of changes
/// (waking from sleep republishes every audio client and every camera) is read twice, as it starts and a moment after
/// the last change, and only a real change reaches the main thread. Runs only while something watches.
final class DeviceActivity: @unchecked Sendable {
    static let shared = DeviceActivity()

    struct State: Equatable, Sendable {
        /// Processes recording from a microphone (macOS 14.2 and later).
        var recording: Set<pid_t> = []
        /// Processes playing or recording sound (macOS 14.2 and later).
        var sounding: Set<pid_t> = []
        var microphoneOn = false
        var cameraOn = false
    }

    /// How long after the last change it reads, and how long a burst may delay a reading at most.
    static let settle: TimeInterval = 0.3
    static let longestWait: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "heartware.devices", qos: .utility)
    private let lock = NSLock()
    private var published = State()
    private var watchers: [UUID: @MainActor (State) -> Void] = [:]
    private var listening = false
    /// The objects that already have their listeners: an object that went away is simply forgotten (removing a
    /// listener from a dead audio client is an error CoreAudio logs, every time).
    private var processes: Set<AudioObjectID> = []
    private var inputs: Set<AudioObjectID> = []
    private var cameras: Set<CMIOObjectID> = []
    private var systemListeners: [() -> Void] = []
    private var pending: DispatchWorkItem?
    private var burstSince: DispatchTime?
    /// Readings made, for the self-test and `--devices-check`.
    private var readings = 0
    var readingCount: Int { queue.sync { readings } }

    private init() {}

    /// The latest state, from any thread (Boost's sweeps read it instead of asking CoreAudio themselves).
    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listeningFlag
    }
    private var listeningFlag = false

    /// `handler` gets the state on the main thread: right away, then at every change.
    func watch(_ handler: @escaping @MainActor (State) -> Void) -> UUID {
        let id = UUID()
        queue.async { [self] in
            if !listening { startListening() }
            watchers[id] = handler
            let now = state
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(now) } }
        }
        return id
    }

    func unwatch(_ id: UUID) {
        queue.async { [self] in
            watchers[id] = nil
            if watchers.isEmpty { stopListening() }
        }
    }

    // MARK: Listening

    private func startListening() {
        listening = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        let audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        var selectors = [kAudioHardwarePropertyDevices]
        if #available(macOS 14.2, *) { selectors.append(kAudioHardwarePropertyProcessObjectList) }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, audioBlock) == noErr {
                systemListeners.append { [queue] in AudioObjectRemovePropertyListenerBlock(system, &address, queue, audioBlock) }
            }
        }
        let cmioSystem = CMIOObjectID(kCMIOObjectSystemObject)
        let cameraBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        var cameraList = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                   mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                   mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        if CMIOObjectAddPropertyListenerBlock(cmioSystem, &cameraList, queue, cameraBlock) == noErr {
            systemListeners.append { [queue] in _ = CMIOObjectRemovePropertyListenerBlock(cmioSystem, &cameraList, queue, cameraBlock) }
        }
        read()
        // Only now: Boost's sweeps read `state` instead of CoreAudio from here on, and it has a first reading.
        lock.lock()
        listeningFlag = true
        lock.unlock()
    }

    private func stopListening() {
        listening = false
        lock.lock()
        listeningFlag = false
        published = State()
        lock.unlock()
        pending?.cancel()
        pending = nil
        burstSince = nil
        systemListeners.forEach { $0() }
        systemListeners = []
        // The listeners on clients and devices still there go too; those that went away are already gone.
        if #available(macOS 14.2, *) {
            let alive = Set(Self.processObjects())
            for id in processes.intersection(alive) { removeProcessListeners(id) }
        }
        let liveInputs = Set(Self.inputDevices())
        for id in inputs.intersection(liveInputs) { removeRunningListener(audio: id) }
        let liveCameras = Set(Self.cameraDevices())
        for id in cameras.intersection(liveCameras) { removeRunningListener(camera: id) }
        processes = []
        inputs = []
        cameras = []
    }

    /// Something changed: read at once (a microphone on for an instant is still seen), then once more when things
    /// settle, a moment after the last change of the burst (`longestWait` at most).
    private func changed() {
        guard listening else { return }
        let now = DispatchTime.now()
        if burstSince == nil {
            burstSince = now
            read()
        }
        pending?.cancel()
        let waited = Double(now.uptimeNanoseconds - (burstSince ?? now).uptimeNanoseconds) / 1e9
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.listening else { return }
            self.burstSince = nil
            self.pending = nil
            self.read()
        }
        pending = work
        queue.asyncAfter(deadline: now + max(0, min(Self.settle, Self.longestWait - waited)), execute: work)
    }

    // MARK: Reading

    /// Listeners on what appeared, then the state; the watchers hear of it only when it changed.
    private func read() {
        readings += 1
        var next = State()
        if #available(macOS 14.2, *) {
            let list = Self.processObjects()
            for id in list where !processes.contains(id) { addProcessListeners(id) }
            processes = Set(list)
            for id in list {
                let input = Self.uint(id, kAudioProcessPropertyIsRunningInput) != 0
                let output = Self.uint(id, kAudioProcessPropertyIsRunningOutput) != 0
                guard input || output, let pid = Self.pid(id) else { continue }
                next.sounding.insert(pid)
                if input { next.recording.insert(pid) }
            }
        }
        let devices = Self.inputDevices()
        for id in devices where !inputs.contains(id) { addRunningListener(audio: id) }
        inputs = Set(devices)
        if #available(macOS 14.2, *) {
            next.microphoneOn = !next.recording.isEmpty
        } else {
            next.microphoneOn = devices.contains { Self.uint($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 }
        }
        let cams = Self.cameraDevices()
        for id in cams where !cameras.contains(id) { addRunningListener(camera: id) }
        cameras = Set(cams)
        next.cameraOn = cams.contains { Self.cameraRunning($0) }
        publish(next)
    }

    private func publish(_ next: State) {
        lock.lock()
        let same = next == published
        published = next
        lock.unlock()
        guard !same else { return }
        for handler in watchers.values {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(next) } }
        }
    }

    private lazy var processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
    private lazy var cameraRunningBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }

    private func addProcessListeners(_ id: AudioObjectID) {
        for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &address, queue, processBlock)
        }
    }

    private func removeProcessListeners(_ id: AudioObjectID) {
        for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, processBlock)
        }
    }

    private static var runningSomewhere: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func addRunningListener(audio id: AudioObjectID) {
        var address = Self.runningSomewhere
        AudioObjectAddPropertyListenerBlock(id, &address, queue, processBlock)
    }

    private func removeRunningListener(audio id: AudioObjectID) {
        var address = Self.runningSomewhere
        AudioObjectRemovePropertyListenerBlock(id, &address, queue, processBlock)
    }

    private static var cameraRunningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    }

    private func addRunningListener(camera id: CMIOObjectID) {
        var address = Self.cameraRunningAddress
        _ = CMIOObjectAddPropertyListenerBlock(id, &address, queue, cameraRunningBlock)
    }

    private func removeRunningListener(camera id: CMIOObjectID) {
        var address = Self.cameraRunningAddress
        _ = CMIOObjectRemovePropertyListenerBlock(id, &address, queue, cameraRunningBlock)
    }

    // MARK: One-shot readings (any thread)

    /// The state right now, read without any listener (`--dump`, the diagnosis).
    static func readNow() -> State {
        var s = State()
        if #available(macOS 14.2, *) {
            for id in processObjects() {
                let input = uint(id, kAudioProcessPropertyIsRunningInput) != 0
                let output = uint(id, kAudioProcessPropertyIsRunningOutput) != 0
                guard input || output, let pid = pid(id) else { continue }
                s.sounding.insert(pid)
                if input { s.recording.insert(pid) }
            }
            s.microphoneOn = !s.recording.isEmpty
        } else {
            s.microphoneOn = inputDevices().contains { uint($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 }
        }
        s.cameraOn = cameraDevices().contains { cameraRunning($0) }
        return s
    }

    /// The audio clients macOS knows (macOS 14.2 and later).
    @available(macOS 14.2, *)
    static func processObjects() -> [AudioObjectID] {
        objects(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    /// The audio devices that can record.
    static func inputDevices() -> [AudioObjectID] {
        objects(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr && size > 0
        }
    }

    static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func cameraRunning(_ id: CMIOObjectID) -> Bool {
        var address = cameraRunningAddress
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr && value != 0
    }

    private static func objects(of owner: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(owner, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(owner, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    @available(macOS 14.2, *)
    private static func pid(_ id: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr && pid > 0 ? pid : nil
    }

    // MARK: Self-test

    /// A burst of changes is read twice, at once and when it settles; nothing reaches the main thread when nothing changed.
    static func selfTest() -> [String] {
        var f: [String] = []
        let watch = DeviceActivity()
        let heard = DispatchSemaphore(value: 0)
        final class Count: @unchecked Sendable { var calls = 0 }
        let count = Count()
        // Not on the main thread: the handler is delivered there, so the test waits off it.
        let id = watch.watch { _ in
            count.calls += 1
            heard.signal()
        }
        let started = DispatchTime.now()
        while heard.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds > 5_000_000_000 { break }
        }
        if count.calls != 1 { f.append("Appareils : l'état de départ n'arrive pas au fil principal") }
        let before = watch.queue.sync { watch.readings }
        watch.queue.sync { for _ in 0..<50 { watch.changed() } }
        Thread.sleep(forTimeInterval: settle + 0.4)
        let after = watch.queue.sync { watch.readings }
        if after - before != 2 { f.append("Appareils : une rafale de 50 changements donne \(after - before) lectures au lieu de deux (au début, puis au calme)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if count.calls != 1 { f.append("Appareils : le fil principal est prévenu alors que rien n'a changé") }
        watch.unwatch(id)
        watch.queue.sync {}
        if watch.isWatching { f.append("Appareils : les écouteurs restent après le dernier observateur") }
        return f
    }
}
