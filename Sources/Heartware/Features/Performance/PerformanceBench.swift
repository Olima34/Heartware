import Foundation
import Compression
import CryptoKit
import Accelerate
import Metal
import Darwin

// MARK: - Tests and results

enum PerformanceBenchTest: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpuSingle, cpuMulti, gpu, memory, disk, latency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuSingle: return "Processeur, 1 cœur"
        case .cpuMulti: return "Processeur, tous les cœurs"
        case .gpu: return "Graphisme (GPU)"
        case .memory: return "Mémoire vive"
        case .disk: return "Disque (SSD)"
        case .latency: return "Réactivité"
        }
    }

    var symbol: String {
        switch self {
        case .cpuSingle: return "cpu"
        case .cpuMulti: return "square.grid.3x3.fill"
        case .gpu: return "cube.transparent"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .latency: return "hand.tap"
        }
    }

    var detail: String {
        switch self {
        case .cpuSingle: return "Compression, chiffrement et calcul sur un cœur : la vitesse ressentie dans la plupart des apps."
        case .cpuMulti: return "Le même travail sur tous les cœurs à la fois : exports, compilations, rendus."
        case .gpu: return "Une scène 3D calculée en 1440p par la puce graphique (Metal), en images par seconde."
        case .memory: return "Débit de copie en mémoire vive, sur plusieurs cœurs."
        case .disk: return "Écriture puis lecture d'un fichier de test d'1 Go, sans cache, aussitôt supprimé."
        case .latency: return "Le temps qu'attend une tâche urgente avant d'avoir un cœur : les saccades viennent de là."
        }
    }

    /// The raw value that scores 1 000, measured on a MacBook Air M2 (8 cœurs, 10 cœurs graphiques, 8 Go, 256 Go),
    /// Boost off, plugged in, ordinary apps open.
    var reference: Double {
        switch self {
        case .cpuSingle: return 560         // units per second
        case .cpuMulti: return 2900         // units per second
        case .gpu: return 80                // frames per second
        case .memory: return 64             // GB/s
        case .disk: return 2000             // MB/s, average of write and read
        case .latency: return 55            // µs, 99th percentile
        }
    }

    var higherIsBetter: Bool { self != .latency }

    func score(_ raw: Double) -> Double {
        guard raw > 0 else { return 0 }
        return higherIsBetter ? 1000 * raw / reference : 1000 * reference / raw
    }

    func format(_ raw: Double) -> String {
        switch self {
        case .cpuSingle, .cpuMulti: return "\(Fmt.int(raw)) opérations/s"
        case .gpu: return "\(Fmt.int(raw)) images/s"
        case .memory: return "\(Fmt.dec(raw)) Go/s"
        case .disk: return "\(Fmt.int(raw)) Mo/s"
        case .latency: return "\(Fmt.int(raw)) µs"
        }
    }
}

struct PerformanceBenchResult: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var mode: PerformanceMode
    /// Raw value of each test (rawValue keys).
    var values: [String: Double]
    /// Details: "diskWrite", "diskRead" (MB/s), "latencyMedian" (µs).
    var extra: [String: Double] = [:]
    var chip: String
    var onBattery: Bool
    var lowPower: Bool
    var tempStart: Double?
    var tempEnd: Double?
    var powerPeak: Double?

    func value(_ t: PerformanceBenchTest) -> Double? { values[t.rawValue] }
    func score(_ t: PerformanceBenchTest) -> Double? { value(t).map(t.score) }

    /// Geometric mean of the scores: one test twice as fast counts as much as any other.
    var total: Double { total(over: Set(PerformanceBenchTest.allCases)) }

    /// The same mean over some tests only: two runs are compared on the tests both have (a disk test can be skipped).
    func total(over tests: Set<PerformanceBenchTest>) -> Double {
        let s = PerformanceBenchTest.allCases.filter(tests.contains).compactMap { score($0) }.filter { $0 > 0 }
        guard !s.isEmpty else { return 0 }
        return exp(s.map(log).reduce(0, +) / Double(s.count))
    }

    var measured: Set<PerformanceBenchTest> { Set(PerformanceBenchTest.allCases.filter { (score($0) ?? 0) > 0 }) }

    /// How much faster than `base` (0.12 = 12 % faster), on the tests both runs have.
    func gain(over base: PerformanceBenchResult) -> Double? {
        let common = measured.intersection(base.measured)
        let b = base.total(over: common)
        return common.isEmpty || b <= 0 ? nil : total(over: common) / b - 1
    }

    var context: String {
        var parts = ["Boost \(mode.title.lowercased())"]
        parts.append(onBattery ? "sur batterie" : "sur secteur")
        if lowPower { parts.append("économie d'énergie") }
        return parts.joined(separator: " · ")
    }
}

/// The Boost test: the app in front alone, then with busy work in the background, then with that work moved by the Boost.
struct PerformanceBoostDemoResult: Codable, Equatable, Sendable {
    struct Phase: Codable, Equatable, Sendable {
        var foreground: Double     // units per second of the app in front
        var background: Double     // units per second of the background work
        var power: Double?
        var temp: Double?
    }
    var date: Date
    var alone: Phase
    var contended: Phase
    var boosted: Phase

    /// What the background work costs the app in front, then what the Boost gives back (in % of its speed alone).
    var contendedRatio: Double { alone.foreground > 0 ? contended.foreground / alone.foreground : 0 }
    var boostedRatio: Double { alone.foreground > 0 ? boosted.foreground / alone.foreground : 0 }
    var gain: Double { contended.foreground > 0 ? boosted.foreground / contended.foreground - 1 : 0 }
}

struct PerformanceEnduranceResult: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        var second: Double
        var rate: Double
        var temp: Double?
        var pFrequency: Double?
        var power: Double?
    }
    var date: Date
    var windows: [Window]

    /// Worst window against the best one: 100 % means no slowdown from the heat.
    var stability: Double {
        let rates = windows.map(\.rate).filter { $0 > 0 }
        guard let best = rates.max(), let worst = rates.min(), best > 0 else { return 0 }
        return worst / best
    }
}

// MARK: - Engine

/// The measurements themselves. They run on their own threads (never the main one) and stop soon after a cancel.
enum PerformanceBenchEngine {
    typealias Progress = @Sendable (Double) -> Void

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Double] = [:]
        func add(_ v: Double, to slot: Int = 0) { lock.lock(); values[slot, default: 0] += v; lock.unlock() }
        func get(_ slot: Int = 0) -> Double { lock.lock(); defer { lock.unlock() }; return values[slot] ?? 0 }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    // MARK: Processor

    /// 128 Ko of text-like data: compressible like real documents, the same on every Mac.
    private static let corpus: [UInt8] = {
        let words = ["le", "processeur", "mémoire", "fenêtre", "image", "calcul", "réseau", "fichier", "Mac", "rapide", "chaleur",
                     "énergie", "cœur", "graphisme", "disque", "écran", "app", "données", "vitesse", "système"]
        var rng = SeededRNG(state: 0xB0057)
        var out: [UInt8] = []
        out.reserveCapacity(128 * 1024)
        while out.count < 128 * 1024 {
            out += Array(words[Int(rng.next() % UInt64(words.count))].utf8)
            out.append(rng.next() % 9 == 0 ? 0x0A : 0x20)
        }
        return Array(out.prefix(128 * 1024))
    }()

    /// One unit of processor work: LZFSE and zlib compression, decompression, SHA-256 and an FFT, all through
    /// macOS' own optimized libraries (the result does not depend on how this app was compiled).
    private final class Worker {
        let encoded = UnsafeMutablePointer<UInt8>.allocate(capacity: 160 * 1024)
        let decoded = UnsafeMutablePointer<UInt8>.allocate(capacity: 160 * 1024)
        let scratch: UnsafeMutableRawPointer
        let fftSetup: FFTSetup?
        let real = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        let imag = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        var sink: UInt64 = 0

        init() {
            let size = max(compression_encode_scratch_buffer_size(COMPRESSION_LZFSE), compression_encode_scratch_buffer_size(COMPRESSION_ZLIB),
                           compression_decode_scratch_buffer_size(COMPRESSION_LZFSE))
            scratch = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
            fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
            for i in 0..<2048 {
                real[i] = sinf(Float(i) * 0.013)
                imag[i] = cosf(Float(i) * 0.007)
            }
        }

        deinit {
            encoded.deallocate()
            decoded.deallocate()
            scratch.deallocate()
            real.deallocate()
            imag.deallocate()
            if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        }

        func unit() {
            PerformanceBenchEngine.corpus.withUnsafeBufferPointer { src in
                let n = src.count
                let lz = compression_encode_buffer(encoded, 160 * 1024, src.baseAddress!, n, scratch, COMPRESSION_LZFSE)
                let back = compression_decode_buffer(decoded, 160 * 1024, encoded, lz, scratch, COMPRESSION_LZFSE)
                let zl = compression_encode_buffer(encoded, 160 * 1024, src.baseAddress!, n / 2, scratch, COMPRESSION_ZLIB)
                var h = SHA256()
                h.update(bufferPointer: UnsafeRawBufferPointer(src))
                let digest = h.finalize()
                sink &+= UInt64(lz + back + zl) &+ UInt64(digest.withUnsafeBytes { $0.first ?? 0 })
            }
            if let fftSetup {
                var split = DSPSplitComplex(realp: real, imagp: imag)
                for _ in 0..<8 {
                    vDSP_fft_zip(fftSetup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                    vDSP_fft_zip(fftSetup, &split, 1, 11, FFTDirection(FFT_INVERSE))
                    var scale: Float = 1.0 / 2048
                    vDSP_vsmul(real, 1, &scale, real, 1, 2048)
                    vDSP_vsmul(imag, 1, &scale, imag, 1, 2048)
                }
            }
        }
    }

    /// Units per second over `duration` on `threads` threads (after a short warm-up).
    static func cpu(threads: Int, duration: TimeInterval, cancel: CancelFlag, progress: Progress? = nil) -> Double {
        let counter = Counter()
        let warmup = 0.4
        let start = Date()
        let measureFrom = start.addingTimeInterval(warmup)
        let end = measureFrom.addingTimeInterval(duration)
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            let t = Thread {
                let w = Worker()
                var done = 0.0
                while !cancel.isCancelled {
                    let now = Date()
                    if now >= end { break }
                    w.unit()
                    if now >= measureFrom { done += 1 }
                }
                counter.add(done)
                group.leave()
            }
            t.qualityOfService = .userInteractive
            t.stackSize = 1 << 20
            t.start()
        }
        waitFor(group, until: end, from: start, progress: progress)
        return cancel.isCancelled ? 0 : counter.get() / duration
    }

    /// Waits for the threads while reporting the elapsed fraction (at most 4 times a second).
    private static func waitFor(_ group: DispatchGroup, until end: Date, from start: Date, progress: Progress?) {
        let total = end.timeIntervalSince(start)
        while group.wait(timeout: .now() + 0.25) == .timedOut {
            progress?(min(1, Date().timeIntervalSince(start) / total))
        }
        progress?(1)
    }

    // MARK: Graphics

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct HWOut { float4 position [[position]]; float2 uv; };

    vertex HWOut hw_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        HWOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = p;
        return o;
    }

    static float hw_scene(float3 p, float t) {
        float3 q = fract(p * 0.5 + 0.5) * 2.0 - 1.0;
        float sphere = length(q) - 0.45 - 0.08 * sin(t + p.x * 1.7);
        float box = length(max(abs(q) - float3(0.32), 0.0)) - 0.05;
        return min(sphere, mix(box, sphere, 0.5 + 0.5 * sin(t * 0.7 + p.z)));
    }

    fragment float4 hw_fragment(HWOut in [[stage_in]], constant float &t [[buffer(0)]]) {
        float2 uv = in.uv * 2.0 - 1.0;
        uv.x *= 16.0 / 9.0;
        float3 ro = float3(0.3 * sin(t), 0.2, t * 0.6);
        float3 rd = normalize(float3(uv, 1.6));
        float d = 0.0;
        float glow = 0.0;
        for (int i = 0; i < 80; i++) {
            float h = hw_scene(ro + rd * d, t);
            glow += 0.02 / (0.05 + abs(h));
            d += max(h * 0.7, 0.012);
        }
        float3 p = ro + rd * d;
        float2 e = float2(0.002, 0.0);
        float3 n = normalize(float3(hw_scene(p + e.xyy, t) - hw_scene(p - e.xyy, t),
                                    hw_scene(p + e.yxy, t) - hw_scene(p - e.yxy, t),
                                    hw_scene(p + e.yyx, t) - hw_scene(p - e.yyx, t)));
        float light = max(dot(n, normalize(float3(0.4, 0.8, -0.5))), 0.0);
        float3 col = float3(0.85, 0.5, 0.35) * light + glow * 0.004 * float3(0.3, 0.5, 1.0);
        return float4(col * exp(-0.04 * d), 1.0);
    }
    """

    /// Frames per second of a raymarched scene drawn off screen in 2560 × 1440, three frames in flight.
    static func gpu(duration: TimeInterval, cancel: CancelFlag, progress: Progress? = nil) -> Double? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "hw_vertex"), let fragment = library.makeFunction(name: "hw_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2560, height: 1440, mipmapped: false)
        texDesc.usage = .renderTarget
        texDesc.storageMode = .private
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc),
              let target = device.makeTexture(descriptor: texDesc) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        let inFlight = DispatchSemaphore(value: 3)
        let counter = Counter()
        let warmup = 0.5
        let start = Date()
        let measureFrom = start.addingTimeInterval(warmup)
        let end = measureFrom.addingTimeInterval(duration)
        var frame = 0
        var failed = false
        var lastReport = Date.distantPast
        while Date() < end && !cancel.isCancelled {
            inFlight.wait()
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
                inFlight.signal()
                failed = true
                break
            }
            var t = Float(frame) * 0.016
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&t, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cb.addCompletedHandler { _ in
                if Date() >= measureFrom && Date() <= end { counter.add(1) }
                inFlight.signal()
            }
            cb.commit()
            frame += 1
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress?(min(1, Date().timeIntervalSince(start) / end.timeIntervalSince(start)))
            }
        }
        // Let the frames in flight end before the textures go away (and the semaphore with its initial count).
        for _ in 0..<3 { inFlight.wait() }
        for _ in 0..<3 { inFlight.signal() }
        progress?(1)
        return cancel.isCancelled || failed ? nil : counter.get() / duration
    }

    // MARK: Memory

    /// Copy bandwidth (GB/s) with one thread per two cores, 32 MB buffers (far beyond the caches).
    static func memory(duration: TimeInterval, cancel: CancelFlag, progress: Progress? = nil) -> Double {
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        let size = 32 << 20
        let counter = Counter()
        let start = Date()
        let measureFrom = start.addingTimeInterval(0.2)
        let end = measureFrom.addingTimeInterval(duration)
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            let t = Thread {
                let src = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                let dst = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                memset(src, 0x5A, size)
                memset(dst, 0, size)
                var bytes = 0.0
                while !cancel.isCancelled {
                    let now = Date()
                    if now >= end { break }
                    memcpy(dst, src, size)
                    if now >= measureFrom { bytes += Double(size) }
                }
                src.deallocate()
                dst.deallocate()
                counter.add(bytes)
                group.leave()
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
        waitFor(group, until: end, from: start, progress: progress)
        return cancel.isCancelled ? 0 : counter.get() / duration / 1e9
    }

    // MARK: Disk

    /// Writes then reads a 1 GB file in the app's data folder, bypassing the cache, then deletes it.
    /// nil when there is not enough room (less than 6 GB free) or in demo mode.
    static func disk(cancel: CancelFlag, progress: Progress? = nil) -> (write: Double, read: Double)? {
        guard !DemoData.isEnabled, let folder = DataStore.ensureFolder("benchmark") else { return nil }
        // A test interrupted by a quit left its file behind: it goes first.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".test") {
            Remover.removeInternal(folder.appendingPathComponent(name).path)
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard (values?.volumeAvailableCapacity ?? 0) > 6_000_000_000 else { return nil }
        guard let url = try? FileOps.write(Data(), to: folder.appendingPathComponent("disque.test")) else { return nil }
        defer { Remover.removeInternal(url.path) }
        let chunk = 8 << 20
        let total = 1 << 30
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        // Random bytes: nothing to gain from compression or deduplication.
        arc4random_buf(buffer, chunk)

        let wfd = open(url.path, O_WRONLY)
        guard wfd >= 0 else { return nil }
        _ = fcntl(wfd, F_NOCACHE, 1)
        var written = 0
        let w0 = Date()
        while written < total && !cancel.isCancelled && Date().timeIntervalSince(w0) < 4 {
            let n = Darwin.write(wfd, buffer, chunk)
            if n <= 0 { break }
            written += n
            progress?(0.5 * Double(written) / Double(total))
        }
        _ = fcntl(wfd, F_FULLFSYNC)
        close(wfd)
        let writeTime = Date().timeIntervalSince(w0)
        guard written > 0, !cancel.isCancelled else { return nil }

        let rfd = open(url.path, O_RDONLY)
        guard rfd >= 0 else { return nil }
        _ = fcntl(rfd, F_NOCACHE, 1)
        var read = 0
        let r0 = Date()
        while !cancel.isCancelled && Date().timeIntervalSince(r0) < 4 {
            let n = Darwin.read(rfd, buffer, chunk)
            if n <= 0 { break }
            read += n
            progress?(0.5 + 0.5 * Double(read) / Double(written))
        }
        close(rfd)
        let readTime = Date().timeIntervalSince(r0)
        guard read > 0, !cancel.isCancelled else { return nil }
        return (Double(written) / writeTime / 1e6, Double(read) / readTime / 1e6)
    }

    // MARK: Responsiveness

    /// Wakes an urgent thread 2 000 times with a direct signal and measures how long it takes to get a core (µs).
    /// No timer is involved, so macOS' timer coalescing does not blur it: what remains is the wait for a free core,
    /// where stutters come from when the background is busy.
    static func latency(cancel: CancelFlag, progress: Progress? = nil) -> (median: Double, p99: Double)? {
        final class Box: @unchecked Sendable {
            var sent: UInt64 = 0
            var late: [Double] = []
        }
        let box = Box()
        let go = DispatchSemaphore(value: 0)
        let back = DispatchSemaphore(value: 0)
        let count = 2000
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticksPerMicro = 1000.0 * Double(tb.denom) / Double(tb.numer)
        box.late.reserveCapacity(count)
        let waiter = Thread {
            for _ in 0..<count {
                go.wait()
                let now = mach_absolute_time()
                box.late.append(Double(now &- box.sent) / ticksPerMicro)
                back.signal()
            }
        }
        waiter.qualityOfService = .userInteractive
        waiter.start()
        for i in 0..<count {
            if cancel.isCancelled {
                // The waiter still expects its signals: let it finish at once.
                for _ in i..<count {
                    go.signal()
                    back.wait()
                }
                break
            }
            usleep(500)
            box.sent = mach_absolute_time()
            go.signal()
            back.wait()
            if i % 250 == 0 { progress?(Double(i) / Double(count)) }
        }
        progress?(1)
        guard !cancel.isCancelled, box.late.count == count else { return nil }
        let sorted = box.late.sorted()
        return (sorted[count / 2], sorted[Int(Double(count) * 0.99)])
    }

    // MARK: Boost test

    /// Measures the Boost's own lever on this Mac, with no other app involved: busy background threads first compete
    /// with the app in front, then move to the background band (efficiency cores), exactly like the Boost moves apps.
    static func boostDemo(cancel: CancelFlag, progress: Progress? = nil) -> PerformanceBoostDemoResult? {
        let phase = 3.0
        let fgThreads = max(1, performanceCores())
        let bgThreads = ProcessInfo.processInfo.activeProcessorCount
        let fg = Counter(), bg = Counter()
        let state = Counter()           // slot 0: phase number (0, 1, 2); slot 1: 1 when everything must stop
        let start = Date()
        let group = DispatchGroup()

        // The app in front: one busy thread per performance core.
        for _ in 0..<fgThreads {
            group.enter()
            let t = Thread {
                let w = Worker()
                while state.get(1) == 0 && !cancel.isCancelled {
                    w.unit()
                    fg.add(1, to: Int(state.get(0)))
                }
                group.leave()
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
        // Background work, started for the second phase, moved to the background band for the third.
        let bgStarted = Flag()
        func startBackground() {
            for _ in 0..<bgThreads {
                group.enter()
                let t = Thread {
                    let w = Worker()
                    var demoted = false
                    while state.get(1) == 0 && !cancel.isCancelled {
                        let p = Int(state.get(0))
                        if p == 2 && !demoted {
                            pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0)
                            demoted = true
                        }
                        w.unit()
                        bg.add(1, to: p)
                    }
                    group.leave()
                }
                t.qualityOfService = .default
                t.start()
            }
            bgStarted.set()
        }

        var phases: [PerformanceBoostDemoResult.Phase] = []
        for p in 0..<3 {
            if cancel.isCancelled { break }
            if p == 1 && !bgStarted.isSet { startBackground() }
            // Each phase settles for half a second, then counts.
            state.add(Double(p) - state.get(0), to: 0)
            let settle = Date().addingTimeInterval(0.5)
            while Date() < settle && !cancel.isCancelled { usleep(50_000) }
            let fg0 = fg.get(p), bg0 = bg.get(p)
            let t0 = Date()
            while Date().timeIntervalSince(t0) < phase && !cancel.isCancelled {
                usleep(250_000)
                progress?(min(1, Date().timeIntervalSince(start) / (3 * (phase + 0.5))))
            }
            let dt = Date().timeIntervalSince(t0)
            let sensors = PerformanceSensorReader.shared.sample()
            phases.append(.init(foreground: (fg.get(p) - fg0) / dt, background: (bg.get(p) - bg0) / dt,
                                power: sensors.systemPower, temp: sensors.chipTemp))
        }
        state.add(1, to: 1)
        group.wait()
        progress?(1)
        guard !cancel.isCancelled, phases.count == 3 else { return nil }
        return PerformanceBoostDemoResult(date: Date(), alone: phases[0], contended: phases[1], boosted: phases[2])
    }

    // MARK: Endurance

    /// Every core busy for `duration`, measured per 10-second window with the temperature and the frequency:
    /// shows when the Mac starts holding back to cool down.
    static func endurance(duration: TimeInterval, cancel: CancelFlag, progress: Progress? = nil,
                          onWindow: (@Sendable (PerformanceEnduranceResult.Window) -> Void)? = nil) -> [PerformanceEnduranceResult.Window] {
        let counter = Counter()
        let stop = Flag()
        let group = DispatchGroup()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            group.enter()
            let t = Thread {
                let w = Worker()
                while !stop.isSet && !cancel.isCancelled {
                    w.unit()
                    counter.add(1)
                }
                group.leave()
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
        var windows: [PerformanceEnduranceResult.Window] = []
        let start = Date()
        _ = PerformanceSensorReader.shared.sample()
        var last = counter.get()
        var lastDate = start
        while Date().timeIntervalSince(start) < duration && !cancel.isCancelled {
            usleep(250_000)
            progress?(min(1, Date().timeIntervalSince(start) / duration))
            guard Date().timeIntervalSince(lastDate) >= 10 else { continue }
            let now = Date()
            let units = counter.get()
            let s = PerformanceSensorReader.shared.sample()
            let w = PerformanceEnduranceResult.Window(second: now.timeIntervalSince(start), rate: (units - last) / now.timeIntervalSince(lastDate),
                                                      temp: s.chipTemp, pFrequency: s.pCluster?.frequency, power: s.systemPower)
            windows.append(w)
            onWindow?(w)
            last = units
            lastDate = now
        }
        stop.set()
        group.wait()
        progress?(1)
        return windows
    }

    /// Performance cores (all cores on Intel).
    static func performanceCores() -> Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}
