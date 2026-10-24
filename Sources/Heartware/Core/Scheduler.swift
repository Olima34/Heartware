import AppKit

/// Periodic background jobs while the app runs (it stays in the menu bar).
/// The last run of each job is saved, so a job missed while the Mac slept catches up at the next check, but never in
/// the minutes that follow the launch or a wake (of the Mac or of its screens): that is when the user wants the Mac
/// back, and every overdue job would otherwise start at that very moment. Due jobs then run one after the other.
/// Nothing runs in demo or snapshot mode.
@MainActor
final class Scheduler {
    static let shared = Scheduler()

    private struct Job {
        let interval: TimeInterval
        let run: @MainActor () async -> Void
    }

    /// How long nothing is started after the launch or a wake.
    static let settle: TimeInterval = 180

    private var jobs: [String: Job] = [:]
    private var running: Set<String> = []
    private var timer: Timer?
    private let lastRuns = JSONStore<[String: Date]>("scheduler", default: [:])
    /// No job starts before this moment.
    private var quietUntil = Date().addingTimeInterval(Scheduler.settle)
    private var settleTick: DispatchWorkItem?
    private var draining = false

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.woke() }
            }
        }
    }

    /// The Mac or its screens woke up: the jobs wait a few minutes, then the overdue ones run.
    private func woke() {
        quietUntil = Date().addingTimeInterval(Self.settle)
        tickAfterQuiet()
    }

    private func tickAfterQuiet() {
        settleTick?.cancel()
        guard !jobs.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        settleTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, quietUntil.timeIntervalSinceNow + 1), execute: work)
    }

    /// Registers (or replaces) a job. `interval` is the minimum time between two runs.
    func register(_ id: String, every interval: TimeInterval, run: @escaping @MainActor () async -> Void) {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        jobs[id] = Job(interval: interval, run: run)
        startTimer()
    }

    func unregister(_ id: String) {
        jobs[id] = nil
        // Nothing left to run: no more checks at all.
        if jobs.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func lastRun(_ id: String) -> Date? { lastRuns.value[id] }

    /// Runs a job now, whatever its schedule.
    func runNow(_ id: String) async {
        guard let job = jobs[id], !running.contains(id) else { return }
        running.insert(id)
        await job.run()
        lastRuns.value[id] = Date()
        running.remove(id)
    }

    private func startTimer() {
        guard timer == nil else { return }
        // One check every five minutes is plenty for jobs counted in quarters of an hour, hours or days.
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tickAfterQuiet()
    }

    private func tick() {
        let now = Date()
        guard now >= quietUntil else {
            tickAfterQuiet()
            return
        }
        guard !draining else { return }
        let due = jobs.filter { id, job in
            !running.contains(id) && now.timeIntervalSince(lastRuns.value[id] ?? .distantPast) >= job.interval
        }.keys.sorted()
        guard !due.isEmpty else { return }
        draining = true
        Task {
            // A sleep may come between two jobs: what is left waits for the quiet minutes after the wake.
            for id in due where Date() >= quietUntil { await runNow(id) }
            draining = false
        }
    }

}
