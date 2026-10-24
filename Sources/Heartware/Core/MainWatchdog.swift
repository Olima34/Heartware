import Foundation
import Darwin
import notify

/// Watches the main thread from a background thread of its own:
/// - while something outside the app depends on it (the pointer hidden for the whole system by Toolbox, apps moved to
///   the efficiency cores by Boost), a silence of a couple of seconds puts those back, so a hang of Heartware never
///   looks like a hang of the whole Mac;
/// - a longer silence writes where the main thread is stuck (a few samples of its stack) to
///   ~/Library/Logs/Heartware, so that a freeze seen on any Mac can be found and fixed;
/// - when macOS logs out, restarts or shuts down while the main thread does not answer, the app leaves by itself
///   instead of holding the restart up; a main thread that computes for a whole minute without answering makes the
///   app start again (once in half an hour at most).
/// Once the app has launched, a ping every two seconds (every second while a rescue is armed): a few microseconds.
/// In the command-line modes it runs only while a rescue is armed.
final class MainWatchdog: @unchecked Sendable {
    static let shared = MainWatchdog()

    struct Limits {
        /// How long the main thread may stay silent before the rescues run.
        var patience: TimeInterval = 2.5
        /// How long a silence lasts before its stack is written down.
        var reportAfter: TimeInterval = 6
        /// A main thread busy computing this long without answering: the app starts again.
        var restartAfter: TimeInterval = 60
        /// Its share of one core over the silence for that (a thread waiting for a password or a reply uses none).
        var spinning = 0.75
        /// After a logout, restart or shutdown began, how long the main thread may stay silent before the app leaves.
        var endingPatience: TimeInterval = 4
    }

    static let relaunchedKey = "watchdog.relaunched"
    private static let lastRestartKey = "watchdog.lastRestart"

    private let limits: Limits
    /// `--watchdog-check`: what would be written or done is told here instead, and the app never leaves.
    private let rehearsal: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "heartware.watchdog", qos: .userInteractive)
    private var rescues: [String: @Sendable () -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private var timerInterval = 0
    /// When the ping still waiting for the main thread was sent, and how much processor time the main thread had used.
    private var pingSent: DispatchTime?
    private var cpuAtPing: Double = 0
    /// The current silence was written down; the app is starting again or leaving.
    private var reported = false
    private var leaving = false
    /// Set once the app has launched (`start`): the main thread is watched all the time.
    private var main: thread_act_t = 0
    private var started = false
    /// A logout, restart or shutdown began.
    private var endingSince: Date?
    private var tokens: [Int32] = []
    private var lastSlowNote: Date?

    private init(limits: Limits = Limits(), rehearsal: (@Sendable (String) -> Void)? = nil) {
        self.limits = limits
        self.rehearsal = rehearsal
    }

    /// At launch, on the main thread: remembers it, listens for the end of the session and starts the ping.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let thread = pthread_mach_thread_np(pthread_self())
        queue.async { [self] in
            guard !started else { return }
            main = thread
            started = true
            listenForSessionEnd()
            schedule()
        }
    }

    /// `rescue` runs once, on a background thread, if the main thread hangs while it is armed. Arming again replaces it.
    func arm(_ id: String, rescue: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            rescues[id] = rescue
            schedule()
        }
    }

    func disarm(_ id: String) {
        queue.async { [self] in
            rescues[id] = nil
            schedule()
        }
    }

    // MARK: The ping

    /// Every second while a rescue is armed, every two seconds otherwise once the app runs, else not at all.
    private func schedule() {
        let every = rescues.isEmpty ? (started ? 2 : 0) : 1
        guard every > 0 else {
            timer?.cancel()
            timer = nil
            timerInterval = 0
            pingSent = nil
            return
        }
        guard every != timerInterval else { return }
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.schedule(deadline: .now() + .seconds(every), repeating: .seconds(every), leeway: .milliseconds(every * 500))
            t.resume()
        } else {
            timer?.schedule(deadline: .now() + .seconds(every), repeating: .seconds(every), leeway: .milliseconds(every * 500))
        }
        timerInterval = every
    }

    private func tick() {
        guard let sent = pingSent else {
            pingSent = .now()
            cpuAtPing = mainCPU()
            DispatchQueue.main.async { [self] in
                queue.async { self.answered() }
            }
            return
        }
        let silent = seconds(since: sent)
        if silent > limits.patience, !rescues.isEmpty { runRescues() }
        guard started, !leaving else { return }
        if let since = endingSince {
            if Date().timeIntervalSince(since) > 120 {
                endingSince = nil
            } else if silent > limits.endingPatience {
                leave(silent: silent)
                return
            }
        }
        if silent > limits.reportAfter, !reported {
            reported = true
            report(samples: 5, note: nil)
        }
        if silent > limits.restartAfter, (mainCPU() - cpuAtPing) / silent >= limits.spinning { restart(silent: silent) }
    }

    private func answered() {
        if let sent = pingSent {
            let late = seconds(since: sent)
            if reported {
                log("BLOCAGE terminé : le fil principal répond de nouveau après \(Int(late.rounded())) s")
            } else if late > 1, started, lastSlowNote.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                // Short of a report: a line, once a minute at most, so that a short freeze can be told from a slow Mac.
                lastSlowNote = Date()
                log("LENTEUR : le fil principal a mis \(Fmt.dec(late)) s à répondre")
            }
        }
        pingSent = nil
        reported = false
    }

    private func seconds(since time: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) / 1e9
    }

    private func log(_ line: String) {
        if let rehearsal { rehearsal(line) } else { ActionLog.write(line) }
    }

    /// Everything armed is put back now, once, away from this queue. `wait`: until they are done, at most that long.
    private func runRescues(wait: TimeInterval = 0) {
        let pending = Array(rescues.values)
        rescues.removeAll()
        schedule()
        let group = DispatchGroup()
        for rescue in pending { DispatchQueue.global(qos: .userInteractive).async(group: group, execute: rescue) }
        if wait > 0 { _ = group.wait(timeout: .now() + wait) }
    }

    /// The processor time the main thread has used so far, in seconds.
    private func mainCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(main, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    // MARK: Leaving

    /// The names loginwindow posts as a logout, restart or shutdown begins, and when it is cancelled.
    /// (Exactly as loginwindow spells them: `restartinitiated` all lower case, `logoutInitiated` and `shutdownInitiated` not.)
    private static let endingNames = ["com.apple.system.loginwindow.likelyShutdown", "com.apple.system.loginwindow.likelyUserSessionExit",
                                      "com.apple.system.loginwindow.restartinitiated", "com.apple.system.loginwindow.shutdownInitiated",
                                      "com.apple.system.loginwindow.logoutInitiated", "com.apple.system.loginwindow.shutdownNoReturn",
                                      "com.apple.system.loginwindow.logoutNoReturn"]
    private static let cancelledName = "com.apple.system.loginwindow.logoutcancelled"
    /// `--watchdog-check` posts this one: it never reaches loginwindow's listeners.
    static let rehearsalEndingName = "io.github.olima34.cleanmyclaude.watchdog-check.ending"

    private func listenForSessionEnd() {
        let names = rehearsal == nil ? Self.endingNames + [Self.cancelledName] : [Self.rehearsalEndingName]
        for name in names {
            var token: Int32 = 0
            let cancelled = name == Self.cancelledName
            let status = notify_register_dispatch(name, &token, queue) { [weak self] _ in
                guard let self else { return }
                if cancelled { self.endingSince = nil } else if self.endingSince == nil { self.endingSince = Date() }
            }
            if status == NOTIFY_STATUS_OK { tokens.append(token) }
        }
    }

    /// macOS is ending the session and the main thread does not answer: what the app changed outside goes back, the
    /// stack is written down, and the app leaves, instead of making macOS say it "ne répond plus".
    private func leave(silent: TimeInterval) {
        leaving = true
        // Writing the report names functions and allocates: if the frozen main thread holds the loader's or the
        // allocator's lock, this queue would wait for ever. Another thread leaves anyway a few seconds from now.
        if rehearsal == nil { DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 5) { _exit(0) } }
        runRescues(wait: 2)
        report(samples: 2, note: "macOS fermait la session : \(AppEdition.name) est parti de lui-même pour ne pas la bloquer.")
        log("BLOCAGE pendant la fin de session : \(AppEdition.name) quitte de lui-même")
        if rehearsal != nil { return }
        ActionLog.flush()
        // What the stores were writing reaches the disk (a second at most).
        let writes = DispatchGroup()
        DataStore.writeQueue.async(group: writes) {}
        _ = writes.wait(timeout: .now() + 1)
        _exit(0)
    }

    /// The main thread has been computing for a minute without answering: the app starts again, once in half an hour.
    private func restart(silent: TimeInterval) {
        if rehearsal != nil {
            leaving = true
            log("BLOCAGE de \(Int(silent.rounded())) s : \(AppEdition.name) redémarrerait de lui-même")
            return
        }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app"), now - defaults.double(forKey: Self.lastRestartKey) > 1800 else { return }
        leaving = true
        runRescues(wait: 2)
        let script = "pid=$1; i=0; while kill -0 \"$pid\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$2\""
        guard Shell.launchDetached("/bin/sh", ["-c", script, "sh", "\(getpid())", bundle]) else {
            leaving = false
            return
        }
        // The new copy starts once this one is gone: whatever happens below, this one goes in a few seconds.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 4) { _exit(0) }
        // Written to disk before leaving: the next launch says why, and no second restart comes within half an hour.
        defaults.set(now, forKey: Self.lastRestartKey)
        defaults.set(true, forKey: Self.relaunchedKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        ActionLog.write("BLOCAGE de \(Int(silent.rounded())) s : \(AppEdition.name) redémarre de lui-même")
        ActionLog.flush()
        _exit(0)
    }

    // MARK: Where it is stuck

    /// A few samples of the main thread's stack, 0.4 s apart, in a file of their own; the action log says where.
    private func report(samples: Int, note: String?) {
        guard let sent = pingSent else { return }
        let buffer = UnsafeMutableBufferPointer<UInt>.allocate(capacity: 96)
        defer { buffer.deallocate() }
        var stacks: [[UInt]] = []
        for i in 0..<samples {
            if i > 0 { usleep(400_000) }
            let n = Self.stack(of: main, into: buffer)
            if n > 0 { stacks.append(Array(buffer.prefix(n))) }
        }
        let silent = seconds(since: sent)
        let cpu = silent > 0 ? min(1, max(0, (mainCPU() - cpuAtPing) / silent)) : 0
        let text = Self.describe(stacks: stacks, silent: silent, cpu: cpu, note: note)
        let summary = "BLOCAGE du fil principal depuis \(Int(silent.rounded())) s (processeur \(Int((cpu * 100).rounded())) %)"
        if let rehearsal {
            rehearsal(summary + "\n" + text)
            return
        }
        let stamp = Self.fileStamp.string(from: Date())
        let url = URL(fileURLWithPath: ActionLog.folder).appendingPathComponent("blocage-\(stamp).txt")
        let written = try? FileOps.write(Data(text.utf8), to: url)
        ActionLog.write(summary + (written.map { " : \($0.path)" } ?? ""))
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return f
    }()

    static func describe(stacks: [[UInt]], silent: TimeInterval, cpu: Double, note: String?) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["\(AppEdition.name) \(version) — le fil principal ne répond plus depuis \(Int(silent.rounded())) s "
                     + "(il a utilisé \(Int((cpu * 100).rounded())) % d'un cœur pendant ce temps).", "macOS \(os)"]
        if let note { lines.append(note) }
        for (i, stack) in stacks.enumerated() {
            lines.append("")
            lines.append("Échantillon \(i + 1) sur \(stacks.count)")
            for (j, address) in stack.enumerated() { lines.append("  \(j)  " + symbol(address, isReturn: j > 0)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "image  function + offset  [image+0xoffset]" for an address in this process.
    static func symbol(_ address: UInt, isReturn: Bool) -> String {
        var info = Dl_info()
        let lookup = isReturn ? address &- 1 : address
        guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0, let file = info.dli_fname else {
            return String(format: "0x%lx", address)
        }
        let image = (String(cString: file) as NSString).lastPathComponent
        let fromImage = address &- UInt(bitPattern: info.dli_fbase)
        guard let raw = info.dli_sname else { return "\(image)  [\(image)+0x\(String(fromImage, radix: 16))]" }
        let name = demangle(String(cString: raw))
        let offset = address &- UInt(bitPattern: info.dli_saddr)
        return "\(image)  \(name.count > 220 ? String(name.prefix(220)) + "…" : name) + \(offset)  [\(image)+0x\(String(fromImage, radix: 16))]"
    }

    private typealias Demangler = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32)
        -> UnsafeMutablePointer<CChar>?
    /// The Swift runtime's own demangler (RTLD_DEFAULT is -2).
    private static let demangler: Demangler? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map {
        unsafeBitCast($0, to: Demangler.self)
    }

    static func demangle(_ name: String) -> String {
        let mangled = name.hasPrefix("_$s") ? String(name.dropFirst()) : name
        guard mangled.hasPrefix("$s"), let demangler else { return name }
        return mangled.withCString { c -> String in
            guard let out = demangler(c, strlen(c), nil, nil, 0) else { return name }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// The return addresses on `thread`'s stack, read while it is suspended for a few microseconds. Nothing that could
    /// take a lock runs meanwhile (the thread may hold the allocator's): the buffer is allocated beforehand, and the
    /// frames are read with `vm_read_overwrite`, which fails instead of crashing on a bad address.
    static func stack(of thread: thread_act_t, into buffer: UnsafeMutableBufferPointer<UInt>) -> Int {
        guard buffer.count >= 3, thread != 0, thread != pthread_mach_thread_np(pthread_self()), thread_suspend(thread) == KERN_SUCCESS else {
            return 0
        }
        // User space addresses fit in 47 bits: higher bits would be a pointer signature.
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var pc: UInt = 0, fp: UInt = 0
        // The caller of a function that keeps no frame of its own (a leaf, a system call): the link register on arm64,
        // the top of the stack on x86_64. Kept apart, it is checked once the thread runs again.
        var maybeCaller: UInt = 0
        var pair: (UInt, UInt) = (0, 0)
        var size: vm_size_t = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            pc = UInt(state.__pc)
            fp = UInt(state.__fp)
            maybeCaller = UInt(state.__lr) & mask
        }
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, x86_THREAD_STATE64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            pc = UInt(state.__rip)
            fp = UInt(state.__rbp)
            let top = withUnsafeMutableBytes(of: &pair) { raw in
                vm_read_overwrite(mach_task_self_, vm_address_t(state.__rsp), vm_size_t(8), vm_address_t(UInt(bitPattern: raw.baseAddress)), &size)
            }
            if top == KERN_SUCCESS, size == 8 { maybeCaller = pair.0 & mask }
        }
        #else
        let kr = KERN_FAILURE
        #endif
        guard kr == KERN_SUCCESS else {
            thread_resume(thread)
            return 0
        }
        buffer[0] = pc & mask
        buffer[1] = 0
        var n = 2
        // Each frame record: the caller's frame pointer, then the return address.
        while n < buffer.count, fp != 0, fp & 7 == 0 {
            let read = withUnsafeMutableBytes(of: &pair) { raw in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(16), vm_address_t(UInt(bitPattern: raw.baseAddress)), &size)
            }
            guard read == KERN_SUCCESS, size == 16 else { break }
            let ret = pair.1 & mask
            if ret != 0 { buffer[n] = ret; n += 1 }
            // The stack grows down: each caller's frame is higher up.
            guard pair.0 & mask > fp else { break }
            fp = pair.0 & mask
        }
        thread_resume(thread)
        // The possible caller counts only when it is neither the next frame nor inside the function the thread is in.
        var keep = maybeCaller != 0 && (n < 3 || maybeCaller != buffer[2])
        if keep {
            var a = Dl_info(), b = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: buffer[0]), &a) != 0, dladdr(UnsafeRawPointer(bitPattern: maybeCaller &- 1), &b) != 0,
               a.dli_saddr != nil, a.dli_saddr == b.dli_saddr {
                keep = false
            }
        }
        if keep {
            buffer[1] = maybeCaller
            return n
        }
        for i in 1..<(n - 1) { buffer[i] = buffer[i + 1] }
        return n - 1
    }

    // MARK: --watchdog-check

    /// Freezes the main thread on purpose, three ways, with short limits, and prints what the watchdog saw and would do:
    /// computing (a report with this function in its stack, then a restart), sleeping (a report, no restart), and a
    /// session ending (it would leave). Nothing is written, nothing restarts. Returns the failures.
    @MainActor static func rehearse() -> [String] {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func add(_ s: String) {
                print(s)
                lock.lock()
                lines.append(s)
                lock.unlock()
            }
            func take() -> [String] {
                lock.lock()
                defer { lines = []; lock.unlock() }
                return lines
            }
        }
        let heard = Heard()
        let short = Limits(patience: 1, reportAfter: 2, restartAfter: 5, spinning: 0.75, endingPatience: 2)
        func freeze(_ seconds: TimeInterval, computing: Bool) {
            let end = Date().addingTimeInterval(seconds)
            if computing {
                var x = 0
                while Date() < end { x &+= 1 }
                if x == -1 { print(x) }
            } else {
                Thread.sleep(until: end)
            }
        }
        func breathe(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func watchdog() -> MainWatchdog {
            let w = MainWatchdog(limits: short, rehearsal: { heard.add($0) })
            w.start()
            breathe(2.5)
            return w
        }
        var f: [String] = []

        let computing = watchdog()
        print("→ Le fil principal calcule 10 s sans répondre…")
        freeze(10, computing: true)
        breathe(3)
        var lines = heard.take()
        if !lines.contains(where: { $0.hasPrefix("BLOCAGE du fil principal") && $0.contains("rehearse") }) {
            f.append("un fil principal qui calcule n'est pas noté, avec l'endroit où il est")
        }
        if !lines.contains(where: { $0.contains("redémarrerait") }) { f.append("un fil principal qui calcule sans fin ne ferait pas redémarrer l'app") }
        if !lines.contains(where: { $0.contains("répond de nouveau") }) { f.append("la fin du blocage n'est pas notée") }

        let sleeping = watchdog()
        print("→ Le fil principal attend 7 s sans répondre…")
        freeze(7, computing: false)
        breathe(3)
        lines = heard.take()
        if !lines.contains(where: { $0.hasPrefix("BLOCAGE du fil principal") }) { f.append("un fil principal qui attend n'est pas noté") }
        if lines.contains(where: { $0.contains("redémarrerait") }) { f.append("un fil principal qui attend (un mot de passe, une réponse) ferait redémarrer l'app") }

        let ending = watchdog()
        print("→ macOS ferme la session pendant que le fil principal ne répond plus…")
        notify_post(rehearsalEndingName)
        breathe(0.3)
        freeze(6, computing: true)
        breathe(2)
        lines = heard.take()
        if !lines.contains(where: { $0.contains("quitte de lui-même") }) { f.append("une fin de session resterait bloquée par l'app") }
        withExtendedLifetime((computing, sleeping, ending)) {}
        return f
    }

    // MARK: Self-test

    static func selfTest() -> [String] {
        var f: [String] = []
        // A thread that sleeps in a known place: its stack must come back, named.
        final class Port: @unchecked Sendable { var value: thread_act_t = 0 }
        let port = Port()
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            port.value = pthread_mach_thread_np(pthread_self())
            ready.signal()
            _ = done.wait(timeout: .now() + 5)
        }
        t.start()
        ready.wait()
        usleep(50_000)
        let buffer = UnsafeMutableBufferPointer<UInt>.allocate(capacity: 96)
        let n = stack(of: port.value, into: buffer)
        let names = (0..<n).map { symbol(buffer[$0], isReturn: $0 > 0) }
        buffer.deallocate()
        done.signal()
        if n < 3 { f.append("Vigie : la pile d'un fil bloqué n'a pas pu être lue (\(n) adresses)") }
        if !names.contains(where: { $0.contains("libsystem_kernel") }) { f.append("Vigie : la pile d'un fil endormi ne passe pas par le noyau") }
        if !names.contains(where: { $0.contains("MainWatchdog") }) { f.append("Vigie : les fonctions de l'app ne sont pas nommées dans la pile") }
        if stack(of: pthread_mach_thread_np(pthread_self()), into: UnsafeMutableBufferPointer(start: nil, count: 0)) != 0 {
            f.append("Vigie : un fil ne doit jamais se suspendre lui-même")
        }
        if demangle("_$sSS") == "_$sSS" && demangler != nil { f.append("Vigie : les noms Swift ne sont pas lisibles") }
        let text = describe(stacks: [[0x1234]], silent: 7.4, cpu: 0.98, note: nil)
        if !text.contains("depuis 7 s") || !text.contains("98 %") || !text.contains("Échantillon 1 sur 1") { f.append("Vigie : le rapport de blocage est mal écrit") }
        return f
    }
}
