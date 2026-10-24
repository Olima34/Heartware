import Foundation
import Observation

/// Runs the benchmarks one at a time and keeps their history (the proof that an optimization changed something).
@Observable
@MainActor
final class PerformanceBenchModel {
    enum Job: Equatable {
        case full, boostDemo, endurance
    }

    nonisolated static let enduranceDuration: TimeInterval = 180
    /// Seconds each test takes, for the progress bar.
    static let weights: [PerformanceBenchTest: Double] = [.cpuSingle: 4.4, .cpuMulti: 4.4, .gpu: 4.5, .memory: 1.7, .disk: 3, .latency: 1.6]

    var job: Job?
    var progress: Double = 0
    var currentTest: PerformanceBenchTest?
    /// Values of the benchmark in progress, test by test.
    var partial: [String: Double] = [:]
    var history: [PerformanceBenchResult] {
        didSet { store.value = Array(history.suffix(40)) }
    }
    var boostDemo: PerformanceBoostDemoResult? {
        didSet { demoStore.value = boostDemo }
    }
    var endurance: PerformanceEnduranceResult? {
        didSet { enduranceStore.value = endurance }
    }
    var liveWindows: [PerformanceEnduranceResult.Window] = []
    var message: String?

    @ObservationIgnored private let store: JSONStore<[PerformanceBenchResult]>
    @ObservationIgnored private let demoStore: JSONStore<PerformanceBoostDemoResult?>
    @ObservationIgnored private let enduranceStore: JSONStore<PerformanceEnduranceResult?>
    @ObservationIgnored private var cancel: CancelFlag?

    init() {
        let s = JSONStore<[PerformanceBenchResult]>("performance-benchmarks", default: [])
        let d = JSONStore<PerformanceBoostDemoResult?>("performance-boost-test", default: nil)
        let e = JSONStore<PerformanceEnduranceResult?>("performance-endurance", default: nil)
        store = s
        demoStore = d
        enduranceStore = e
        history = s.value
        boostDemo = d.value
        endurance = e.value
    }

    var isRunning: Bool { job != nil }
    var latest: PerformanceBenchResult? { history.last }

    /// The run to compare the latest one with: the previous run in another Boost mode, or else the previous run.
    var baseline: PerformanceBenchResult? {
        guard let last = history.last, history.count > 1 else { return nil }
        let earlier = history.dropLast()
        return earlier.last { $0.mode != last.mode } ?? earlier.last
    }

    func cancelJob() {
        cancel?.cancel()
    }

    private func begin(_ j: Job) -> CancelFlag? {
        guard job == nil else { return nil }
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            message = DemoData.refusal
            return nil
        }
        let flag = CancelFlag()
        cancel = flag
        job = j
        progress = 0
        message = nil
        return flag
    }

    /// Progress for the main thread, at most 4 times a second (the disk test reports every 8 MB).
    private func reporter(from base: Double, span: Double) -> PerformanceBenchEngine.Progress {
        final class Last: @unchecked Sendable {
            let lock = NSLock()
            var at = Date.distantPast
        }
        let last = Last()
        return { [weak self] f in
            last.lock.lock()
            let now = Date()
            let due = f >= 1 || now.timeIntervalSince(last.at) >= 0.25
            if due { last.at = now }
            last.lock.unlock()
            guard due else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.progress = base + span * f }
            }
        }
    }

    // MARK: Full benchmark

    func runFull(mode: PerformanceMode, onBattery: Bool) {
        guard let flag = begin(.full) else { return }
        partial = [:]
        let total = Self.weights.values.reduce(0, +)
        Task {
            let first = await Task.detached { PerformanceSensorReader.shared.sample() }.value
            var extra: [String: Double] = [:]
            var peak = first.systemPower
            var done = 0.0
            for t in PerformanceBenchTest.allCases {
                if flag.isCancelled { break }
                currentTest = t
                let report = reporter(from: done / total, span: (Self.weights[t] ?? 1) / total)
                switch t {
                case .cpuSingle:
                    partial[t.rawValue] = await Task.detached { PerformanceBenchEngine.cpu(threads: 1, duration: 4, cancel: flag, progress: report) }.value
                case .cpuMulti:
                    let threads = ProcessInfo.processInfo.activeProcessorCount
                    partial[t.rawValue] = await Task.detached { PerformanceBenchEngine.cpu(threads: threads, duration: 4, cancel: flag, progress: report) }.value
                    let s = await Task.detached { PerformanceSensorReader.shared.sample() }.value
                    peak = max(peak ?? 0, s.systemPower ?? 0)
                case .gpu:
                    partial[t.rawValue] = await Task.detached { PerformanceBenchEngine.gpu(duration: 4, cancel: flag, progress: report) }.value
                    let s = await Task.detached { PerformanceSensorReader.shared.sample() }.value
                    peak = max(peak ?? 0, s.systemPower ?? 0)
                case .memory:
                    partial[t.rawValue] = await Task.detached { PerformanceBenchEngine.memory(duration: 1.5, cancel: flag, progress: report) }.value
                case .disk:
                    if let d = await Task.detached(operation: { PerformanceBenchEngine.disk(cancel: flag, progress: report) }).value {
                        partial[t.rawValue] = (d.write + d.read) / 2
                        extra["diskWrite"] = d.write
                        extra["diskRead"] = d.read
                    }
                case .latency:
                    if let l = await Task.detached(operation: { PerformanceBenchEngine.latency(cancel: flag, progress: report) }).value {
                        partial[t.rawValue] = l.p99
                        extra["latencyMedian"] = l.median
                    }
                }
                done += Self.weights[t] ?? 1
                // A short breath between tests, so that one does not heat the next.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let last = await Task.detached { PerformanceSensorReader.shared.sample() }.value
            currentTest = nil
            job = nil
            cancel = nil
            guard !flag.isCancelled else {
                message = "Benchmark annulé."
                return
            }
            let result = PerformanceBenchResult(date: Date(), mode: mode, values: partial.filter { $0.value > 0 }, extra: extra,
                                                chip: SystemMonitor.chipName, onBattery: onBattery,
                                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                tempStart: first.chipTemp, tempEnd: last.chipTemp, powerPeak: peak)
            history.append(result)
            ActionLog.write("BENCHMARK score \(Int(result.total))")
        }
    }

    // MARK: Boost test

    func runBoostDemo() {
        guard let flag = begin(.boostDemo) else { return }
        let report = reporter(from: 0, span: 1)
        Task {
            let r = await Task.detached { PerformanceBenchEngine.boostDemo(cancel: flag, progress: report) }.value
            job = nil
            cancel = nil
            if let r { boostDemo = r } else { message = "Test du Boost annulé." }
        }
    }

    // MARK: Endurance

    func runEndurance() {
        guard let flag = begin(.endurance) else { return }
        liveWindows = []
        let report = reporter(from: 0, span: 1)
        let onWindow: @Sendable (PerformanceEnduranceResult.Window) -> Void = { [weak self] w in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.liveWindows.append(w) }
            }
        }
        Task {
            let windows = await Task.detached {
                PerformanceBenchEngine.endurance(duration: Self.enduranceDuration, cancel: flag, progress: report, onWindow: onWindow)
            }.value
            job = nil
            cancel = nil
            if flag.isCancelled || windows.count < 3 {
                message = "Test d'endurance annulé."
            } else {
                endurance = PerformanceEnduranceResult(date: Date(), windows: windows)
            }
            liveWindows = []
        }
    }

    // MARK: Demo

    func loadDemo() {
        history = PerformanceDemo.benchHistory()
        boostDemo = PerformanceDemo.boostDemo()
        endurance = PerformanceDemo.endurance()
    }

    /// `--dump --only performance --bench`: the full benchmark from the command line (nothing is saved).
    nonisolated static func runFromCommandLine() -> [String] {
        let flag = CancelFlag()
        var lines: [String] = []
        let s1 = PerformanceBenchEngine.cpu(threads: 1, duration: 4, cancel: flag)
        lines.append("Processeur 1 cœur : \(PerformanceBenchTest.cpuSingle.format(s1)) → \(Int(PerformanceBenchTest.cpuSingle.score(s1)))")
        let sn = PerformanceBenchEngine.cpu(threads: ProcessInfo.processInfo.activeProcessorCount, duration: 4, cancel: flag)
        lines.append("Processeur tous les cœurs : \(PerformanceBenchTest.cpuMulti.format(sn)) → \(Int(PerformanceBenchTest.cpuMulti.score(sn)))")
        if let g = PerformanceBenchEngine.gpu(duration: 4, cancel: flag) {
            lines.append("GPU : \(PerformanceBenchTest.gpu.format(g)) → \(Int(PerformanceBenchTest.gpu.score(g)))")
        }
        let m = PerformanceBenchEngine.memory(duration: 1.5, cancel: flag)
        lines.append("Mémoire : \(PerformanceBenchTest.memory.format(m)) → \(Int(PerformanceBenchTest.memory.score(m)))")
        if let d = PerformanceBenchEngine.disk(cancel: flag) {
            let avg = (d.write + d.read) / 2
            lines.append("SSD : écriture \(Fmt.int(d.write)) Mo/s, lecture \(Fmt.int(d.read)) Mo/s → \(Int(PerformanceBenchTest.disk.score(avg)))")
        } else {
            lines.append("SSD : test ignoré (place libre ou mode démo)")
        }
        if let l = PerformanceBenchEngine.latency(cancel: flag) {
            lines.append("Réactivité : médiane \(Fmt.int(l.median)) µs, 99 % \(Fmt.int(l.p99)) µs → \(Int(PerformanceBenchTest.latency.score(l.p99)))")
        }
        if CommandLine.arguments.contains("--boost-test"), let b = PerformanceBenchEngine.boostDemo(cancel: flag) {
            lines.append(String(format: "Test du Boost : seule %.0f/s · avec tâches de fond %.0f/s (%.0f %%) · avec le Boost %.0f/s (%.0f %%)",
                                b.alone.foreground, b.contended.foreground, b.contendedRatio * 100, b.boosted.foreground, b.boostedRatio * 100))
            lines.append(String(format: "  tâches de fond : %.0f/s puis %.0f/s · puissance %.1f W → %.1f W · puce %.0f °C → %.0f °C",
                                b.contended.background, b.boosted.background, b.contended.power ?? 0, b.boosted.power ?? 0,
                                b.contended.temp ?? 0, b.boosted.temp ?? 0))
        }
        return lines
    }
}
