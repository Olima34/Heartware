import Foundation

/// The fictional Mac of the demo mode (a MacBook Pro M4 Pro, like `DemoData`): sensors, Boost, benchmarks and settings.
/// Nothing here is read from this Mac.
enum PerformanceDemo {
    private static let now = Date()
    private static func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    static func sensors(tick: Int = 0) -> PerformanceSensorSample {
        let wave = sin(Double(tick) / 4)
        return PerformanceSensorSample(chipTemp: 51.4 + 2.5 * wave, hotspotTemp: 63.9 + 3 * wave, gpuTemp: 43.2, ssdTemp: 38.6, batteryTemp: 31.2,
                                       systemPower: 14.8 + 1.6 * wave, adapterPower: 0, cpuPower: nil, gpuPower: 1.9, gpuUsage: 0.18,
                                       gpuFrequency: 980,
                                       pCluster: PerformanceCluster(frequency: 3_420, maxFrequency: 4_512, active: 0.38),
                                       eCluster: PerformanceCluster(frequency: 1_980, maxFrequency: 2_892, active: 0.61),
                                       fans: [PerformanceFan(id: 0, rpm: 1_840, minRPM: 1_200, maxRPM: 5_800),
                                              PerformanceFan(id: 1, rpm: 1_910, minRPM: 1_200, maxRPM: 5_800)])
    }

    /// The last two minutes of the curves, deterministic.
    static func histories() -> (chip: [Double], power: [Double], gpu: [Double]) {
        let n = PerformanceSensors.historyLength
        let chip = (0..<n).map { i -> Double in
            let x = Double(i)
            return 49 + 4 * sin(x / 7) + (i > 38 && i < 47 ? 9 * sin(Double(i - 38) / 9 * .pi) : 0)
        }
        let power = (0..<n).map { i -> Double in
            let x = Double(i)
            return 13 + 3 * sin(x / 5 + 1) + (i > 38 && i < 47 ? 22 * sin(Double(i - 38) / 9 * .pi) : 0)
        }
        let gpu = (0..<n).map { i in max(0.03, 0.16 + 0.08 * sin(Double(i) / 3)) }
        return (chip, power, gpu)
    }

    static func demotions() -> [PerformanceDemotion] {
        [
            PerformanceDemotion(key: "/Applications/Ruche.app", name: "Ruche", appPath: "/Applications/Ruche.app", bundleID: "com.ruche.desktop",
                                pids: [PerformancePID(pid: 912, start: 1), PerformancePID(pid: 917, start: 1), PerformancePID(pid: 925, start: 1)],
                                since: now.addingTimeInterval(-26 * 60), cause: .busy, cpuBefore: 38.4, cpuNow: 21.7),
            PerformanceDemotion(key: "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd",
                                name: "Analyse des photos", appPath: nil, bundleID: nil, pids: [PerformancePID(pid: 1204, start: 1)],
                                since: now.addingTimeInterval(-9 * 60), cause: .busy, cpuBefore: 64.2, cpuNow: 31.5),
            PerformanceDemotion(key: "/Applications/Nuage Drive.app", name: "Nuage Drive", appPath: "/Applications/Nuage Drive.app",
                                bundleID: "io.nuagedrive.client", pids: [PerformancePID(pid: 1388, start: 1), PerformancePID(pid: 1391, start: 1)],
                                since: now.addingTimeInterval(-3 * 3600), cause: .rule, cpuBefore: 6.1, cpuNow: 2.4)
        ]
    }

    static func busyGroups() -> [PerformanceGroup] {
        [
            PerformanceGroup(key: "/Applications/Hélios Code.app", name: "Hélios Code", appPath: "/Applications/Hélios Code.app",
                             bundleID: "com.helios.code", kind: .app, pids: [PerformancePID(pid: 640, start: 1)], cpu: 61.3, memory: 1_920_000_000),
            PerformanceGroup(key: "/Applications/Safari.app", name: "Safari", appPath: "/Applications/Safari.app", bundleID: "com.apple.Safari",
                             kind: .app, pids: [PerformancePID(pid: 702, start: 1)], cpu: 9.8, memory: 2_180_000_000)
        ]
    }

    private static func result(_ days: Double, mode: PerformanceMode, scale: Double, latency: Double, onBattery: Bool = false) -> PerformanceBenchResult {
        PerformanceBenchResult(date: ago(days), mode: mode,
                               values: ["cpuSingle": 812 * scale, "cpuMulti": 6_960 * scale, "gpu": 164 * scale, "memory": 121 * scale,
                                        "disk": 5_420, "latency": latency],
                               extra: ["diskWrite": 4_960, "diskRead": 5_880, "latencyMedian": 4.6],
                               chip: DemoData.chipName, onBattery: onBattery, lowPower: false,
                               tempStart: 47, tempEnd: 71, powerPeak: 58.4)
    }

    static func benchHistory() -> [PerformanceBenchResult] {
        [
            result(16, mode: .off, scale: 0.86, latency: 1_840),
            result(9, mode: .off, scale: 0.9, latency: 690, onBattery: true),
            result(2, mode: .smart, scale: 0.98, latency: 66),
            result(0.02, mode: .performance, scale: 1.0, latency: 41)
        ]
    }

    static func boostDemo() -> PerformanceBoostDemoResult {
        PerformanceBoostDemoResult(date: ago(0.04),
                                   alone: .init(foreground: 2_050, background: 0, power: 31.8, temp: 58),
                                   contended: .init(foreground: 1_352, background: 3_940, power: 61.5, temp: 81),
                                   boosted: .init(foreground: 2_012, background: 1_310, power: 36.4, temp: 64))
    }

    static func endurance() -> PerformanceEnduranceResult {
        let windows = (1...18).map { i -> PerformanceEnduranceResult.Window in
            let x = Double(i)
            return .init(second: x * 10, rate: 4_660 - 14 * x - (i > 12 ? 40 : 0), temp: 60 + 26 * (1 - exp(-x / 6)),
                         pFrequency: 4_512 - (i > 12 ? 180 : 40), power: 46 - 0.4 * x)
        }
        return PerformanceEnduranceResult(date: ago(1.2), windows: windows)
    }

    /// Three of the Fluidité settings already on.
    static func preference(domain: String?, key: String) -> PerformanceTweakValue? {
        switch (domain, key) {
        case (nil, "NSAutomaticWindowAnimationsEnabled"): return .bool(false)
        case ("com.apple.dock", "launchanim"): return .bool(false)
        case ("com.apple.dock", "mineffect"): return .string("scale")
        case ("com.apple.dock", "autohide-delay"): return .double(0.5)
        default: return nil
        }
    }

    static func displays() -> [PerformanceDisplay] {
        [
            PerformanceDisplay(id: 1, name: "Écran Liquid Retina XDR intégré", resolution: "1512 × 982", current: 120, best: 120, builtIn: true),
            PerformanceDisplay(id: 2, name: "Moniteur 27 pouces", resolution: "2560 × 1440", current: 60, best: 144, builtIn: false)
        ]
    }

    /// The video editor is in front: everything else is in the background.
    static let frontID = "/Applications/Monteur.app"
}
