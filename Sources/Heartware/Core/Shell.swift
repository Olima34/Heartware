import Foundation
import AppKit
import Darwin

/// Runs command line tools and AppleScript.
///
/// Tools outside the system folders (Homebrew's ffmpeg, xz, brew or mas, Claude Code, anything `which` finds in a folder
/// the user can write to) are started "disclaimed": they answer for themselves to macOS instead of inheriting
/// the app's privacy permissions (Full Disk Access, protected folders…), like the commands Terminal, iTerm2 or VS Code run.
/// A program that replaced /opt/homebrew/bin/ffmpeg gets none of what the user granted Heartware.
enum Shell {
    struct Output {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
        /// stdout and stderr together (some tools such as sysadminctl answer on stderr).
        var all: String { out + err }
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    /// Folders only macOS (or an administrator) can change: the tools there run as usual.
    static let systemFolders = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/", "/System/"]
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let homebrewFolders = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]

    /// Variables that make a tool load other code (a library, a startup script, modules): never passed on.
    static let unsafeVariables: Set<String> = [
        "BASH_ENV", "ENV", "ZDOTDIR", "NODE_OPTIONS", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP",
        "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB"
    ]
    static let unsafePrefixes = ["DYLD_", "LD_", "BASH_FUNC_"]

    /// `env` without the variables that inject code into a tool.
    static func scrubbed(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in !unsafeVariables.contains(key) && !unsafePrefixes.contains(where: { key.hasPrefix($0) }) }
    }

    /// The environment of child processes: the app's, scrubbed, with the system folders first in PATH, then Homebrew's
    /// (apps opened from the Finder start with a bare PATH, and `brew`, `mas` or `ffmpeg` live there).
    /// The inherited PATH is dropped: a folder put in front of /usr/bin would choose which `sh` or `git` runs.
    static let environment: [String: String] = {
        var env = scrubbed(ProcessInfo.processInfo.environment)
        env["PATH"] = ([systemPath] + homebrewFolders).joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "fr_FR.UTF-8"
        return env
    }()

    /// Full path of a command line tool, looked up in `environment`'s PATH.
    static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return exists(tool) ? tool : nil }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if exists(p) { return p }
        }
        return nil
    }

    /// True for a tool outside the system folders: it is started without the app's privacy permissions.
    static func isThirdParty(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return !systemFolders.contains { p.hasPrefix($0) }
    }

    /// Runs a tool and waits for it, killing it after `timeout` seconds.
    /// `replaceEnvironment` gives the tool exactly that environment (instead of the app's plus `env`);
    /// `input` is written to its standard input. `disclaim`: nil decides from the path (`isThirdParty`).
    static func run(_ path: String, _ args: [String] = [], env: [String: String] = [:],
                    replaceEnvironment: [String: String]? = nil, input: String? = nil,
                    workingDirectory: String? = nil, timeout: TimeInterval = 20, disclaim: Bool? = nil) -> Output {
        if DemoData.isEnabled { return Output(status: -1, out: "", err: DemoData.refusal) }
        let outPipe = Pipe(), errPipe = Pipe()
        let inPipe = input.map { _ in Pipe() }
        let p: Child
        do {
            p = try start(path, args, environment: replaceEnvironment ?? environment.merging(env) { _, new in new },
                          workingDirectory: workingDirectory, stdin: inPipe?.fileHandleForReading,
                          stdout: outPipe.fileHandleForWriting, stderr: errPipe.fileHandleForWriting,
                          disclaim: disclaim ?? isThirdParty(path))
        } catch {
            return Output(status: -1, out: "", err: error.localizedDescription)
        }
        // The tool has its own copies: ours would keep the pipes open, and the reads below would never end.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        try? inPipe?.fileHandleForReading.close()
        if let inPipe, let input {
            let data = Data(input.utf8)
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        let status = p.waitUntilExit()
        killer.cancel()
        return Output(status: status,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errBox.data, as: UTF8.self))
    }

    /// Runs a long tool (brew, networkQuality, ping…) and hands over each line of output as it comes.
    /// Returns when the tool exits or when `isCancelled` turns true (the tool is then terminated).
    /// Must not be called from the main thread.
    static func stream(_ path: String, _ args: [String] = [], env: [String: String] = [:], disclaim: Bool? = nil,
                       isCancelled: @escaping () -> Bool = { false },
                       onLine: @escaping (String) -> Void) -> Output {
        if DemoData.isEnabled { return Output(status: -1, out: "", err: DemoData.refusal) }
        let pipe = Pipe()
        let p: Child
        do {
            p = try start(path, args, environment: environment.merging(env) { _, new in new }, workingDirectory: nil,
                          stdin: nil, stdout: pipe.fileHandleForWriting, stderr: pipe.fileHandleForWriting,
                          disclaim: disclaim ?? isThirdParty(path))
        } catch {
            return Output(status: -1, out: "", err: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        // A tool may stay silent until it ends (networkQuality -c): the cancel is watched apart from the output.
        let watcher = DispatchWorkItem {
            while p.isRunning {
                if isCancelled() {
                    terminateTree(p)
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: watcher)
        let all = Box()
        var pending = Data()
        let handle = pipe.fileHandleForReading
        while true {
            if isCancelled() {
                terminateTree(p)
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break } // end of file: the tool exited
            all.data.append(chunk)
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                onLine(line)
            }
        }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        let status = p.waitUntilExit()
        watcher.cancel()
        return Output(status: status, out: String(decoding: all.data, as: UTF8.self), err: "")
    }

    /// Stops a tool and the processes it started itself (brew launches ruby, curl, git…).
    private static func terminateTree(_ p: Child) {
        guard p.isRunning else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(p.pid)"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
        p.terminate()
    }

    /// A tool that keeps running (`log stream`): see `follow`.
    final class Following: @unchecked Sendable {
        private let child: Child
        private let source: DispatchSourceRead

        fileprivate init(child: Child, source: DispatchSourceRead) {
            self.child = child
            self.source = source
        }

        /// Stops reading and terminates the tool; `onExit` still comes.
        func stop() {
            source.cancel()
        }

        deinit {
            source.cancel()
        }
    }

    /// Starts a tool that keeps running and hands over each line of its output as it comes, on `queue`: a dispatch
    /// source reads the pipe (no thread waits, no polling, nothing kept but an unfinished line). `onExit` comes once,
    /// on `queue`, after the tool ended or `stop()`. Nil when it could not start (and in demo mode).
    static func follow(_ path: String, _ args: [String], queue: DispatchQueue, onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) -> Following? {
        if DemoData.isEnabled { return nil }
        let pipe = Pipe()
        guard let child = try? start(path, args, environment: environment, workingDirectory: nil, stdin: nil,
                                     stdout: pipe.fileHandleForWriting, stderr: nil, disclaim: isThirdParty(path)) else { return nil }
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        final class Pending: @unchecked Sendable { var data = Data() }
        let pending = Pending()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak source] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else {
                // End of the output (the tool ended), or a real error: done.
                if n == 0 || (errno != EAGAIN && errno != EINTR) { source?.cancel() }
                return
            }
            pending.data.append(contentsOf: buffer[0..<n])
            while let nl = pending.data.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending.data[pending.data.startIndex..<nl], as: UTF8.self))
                pending.data.removeSubrange(pending.data.startIndex...nl)
            }
            // A line that never ends is not kept for ever.
            if pending.data.count > 1 << 20 { pending.data.removeAll() }
        }
        source.setCancelHandler {
            try? reader.close()
            child.terminate()
            DispatchQueue.global(qos: .utility).async {
                let status = child.waitUntilExit()
                queue.async { onExit(status) }
            }
        }
        source.resume()
        return Following(child: child, source: source)
    }

    /// Starts a tool without waiting for it nor reading its output: it keeps running after the app quits
    /// (the relaunch after an update). Nothing in demo mode.
    @discardableResult
    static func launchDetached(_ path: String, _ args: [String] = []) -> Bool {
        if DemoData.isEnabled { return false }
        return (try? start(path, args, environment: environment, workingDirectory: nil, stdin: nil, stdout: nil, stderr: nil,
                           disclaim: isThirdParty(path))) != nil
    }

    /// Runs a command line through /bin/sh.
    static func sh(_ command: String, timeout: TimeInterval = 20) -> Output {
        run("/bin/sh", ["-c", command], timeout: timeout)
    }

    // MARK: Starting a tool

    /// A started tool: a `Process`, or a child spawned without the app's privacy permissions.
    fileprivate final class Child: @unchecked Sendable {
        let pid: pid_t
        private let process: Process?
        private let lock = NSLock()
        private var exited = false
        private var status: Int32 = -1
        private let done = DispatchGroup()

        init(_ process: Process) {
            self.process = process
            pid = process.processIdentifier
        }

        init(spawned pid: pid_t) {
            process = nil
            self.pid = pid
            done.enter()
            Thread.detachNewThread { [self] in reap() }
        }

        /// Waits for the exit without collecting it first, so `terminate` can never reach another process given the same pid.
        private func reap() {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            lock.lock()
            var raw: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(pid, &raw, 0) } while r == -1 && errno == EINTR
            // Like `Process.terminationStatus`: the exit code, or the signal that stopped it.
            if r == pid { status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f }
            exited = true
            lock.unlock()
            done.leave()
        }

        var isRunning: Bool {
            if let process { return process.isRunning }
            lock.lock()
            defer { lock.unlock() }
            return !exited
        }

        func terminate() {
            if let process { return process.terminate() }
            lock.lock()
            if !exited { kill(pid, SIGTERM) }
            lock.unlock()
        }

        func waitUntilExit() -> Int32 {
            if let process {
                process.waitUntilExit()
                return process.terminationStatus
            }
            done.wait()
            lock.lock()
            defer { lock.unlock() }
            return status
        }
    }

    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// `responsibility_spawnattrs_setdisclaim`: not public, but in libSystem since macOS 10.14 and used by Terminal,
    /// iTerm2 or VS Code. Looked up at run time (RTLD_DEFAULT): nil if a macOS ever drops it.
    private static let disclaimFunction: DisclaimFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()

    /// Whether third-party tools really start without the app's permissions on this Mac.
    static var canDisclaim: Bool { disclaimFunction != nil }

    /// `stdin`, `stdout`, `stderr`: nil for /dev/null. With `disclaim` (and the function available), posix_spawn starts
    /// the tool as responsible for itself; otherwise `Process` starts it as before.
    private static func start(_ path: String, _ args: [String], environment: [String: String], workingDirectory: String?,
                              stdin: FileHandle?, stdout: FileHandle?, stderr: FileHandle?, disclaim: Bool) throws -> Child {
        let env = scrubbed(environment)
        guard disclaim, let setDisclaim = disclaimFunction else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = env
            if let workingDirectory { p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
            p.standardInput = stdin ?? FileHandle.nullDevice
            p.standardOutput = stdout ?? FileHandle.nullDevice
            p.standardError = stderr ?? FileHandle.nullDevice
            try p.run()
            return Child(p)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (handle, target) in [(stdin, Int32(0)), (stdout, 1), (stderr, 2)] {
            if let handle {
                posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, target)
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0)
            }
        }
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Like `Process`: no other descriptor of the app, default signal handlers (the app ignores SIGPIPE), none blocked.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        _ = setDisclaim(&attributes, 1)

        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
        return Child(spawned: pid)
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid`, looked up like the disclaim function.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// The process macOS holds responsible for `pid` (whose privacy permissions apply), or nil when it cannot tell.
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let f = responsibleFunction else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    /// `--selftest`: what the environment keeps, which tools count as third-party, and a disclaimed start that behaves
    /// like an ordinary one (output, input, exit code, folder, time limit, cancel) while answering for itself to macOS.
    static func selfTest() -> [String] {
        var f: [String] = []
        let env = scrubbed(["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "LD_PRELOAD": "x", "BASH_FUNC_ls%%": "() { :; }",
                            "NODE_OPTIONS": "--require /tmp/x.js", "PYTHONPATH": "/tmp", "ZDOTDIR": "/tmp", "HOME": "/Users/x", "LANG": "fr_FR.UTF-8"])
        if env.keys.sorted() != ["HOME", "LANG"] { f.append("Environnement des outils mal nettoyé : \(env.keys.sorted())") }
        if environment["PATH"]?.hasPrefix(systemPath + ":") != true { f.append("PATH des outils : les dossiers système doivent venir en premier") }
        for (path, third) in [("/opt/homebrew/bin/ffmpeg", true), ("/usr/local/bin/xz", true), ("/Users/x/.local/bin/claude", true),
                              ("/usr/bin/codesign", false), ("/bin/sh", false), ("/usr/libexec/PlistBuddy", false),
                              ("/System/Library/CoreServices/x", false), ("/usr/bin/../../opt/homebrew/bin/x", true), ("/usr/binx/y", true)]
        where isThirdParty(path) != third {
            f.append("Outil « \(path) » \(third ? "pris pour un outil système" : "pris pour un outil tiers")")
        }
        guard !DemoData.isEnabled else { return f }
        guard canDisclaim else { return f + ["responsibility_spawnattrs_setdisclaim introuvable : les outils tiers héritent des droits de l'app"] }
        let echo = run("/bin/echo", ["bonjour"], disclaim: true)
        if echo.status != 0 || echo.out != "bonjour\n" { f.append("Lancement sans héritage des droits : sortie « \(echo.out) », code \(echo.status)") }
        if run("/bin/sh", ["-c", "echo oups >&2; exit 3"], disclaim: true).all != "oups\n" || run("/bin/sh", ["-c", "exit 3"], disclaim: true).status != 3 {
            f.append("Lancement sans héritage des droits : erreur ou code de sortie perdu")
        }
        if run("/bin/cat", input: "entrée", disclaim: true).out != "entrée" { f.append("Lancement sans héritage des droits : entrée standard perdue") }
        if !run("/bin/pwd", workingDirectory: "/usr/lib", disclaim: true).out.hasPrefix("/usr/lib") { f.append("Lancement sans héritage des droits : dossier de travail ignoré") }
        if run("/usr/bin/env", replaceEnvironment: ["HW": "1", "DYLD_PRINT_LIBRARIES": "1"], disclaim: true).out != "HW=1\n" {
            f.append("Lancement sans héritage des droits : environnement mal transmis")
        }
        var began = Date()
        if run("/bin/sleep", ["10"], timeout: 0.3, disclaim: true).status != SIGTERM || Date().timeIntervalSince(began) > 3 {
            f.append("Lancement sans héritage des droits : délai maximal non appliqué")
        }
        let flag = CancelFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.cancel() }
        began = Date()
        _ = stream("/bin/sleep", ["20"], disclaim: true, isCancelled: { flag.isCancelled }) { _ in }
        if Date().timeIntervalSince(began) > 3 { f.append("Lancement sans héritage des droits : annulation sans effet") }
        // The child answers for itself to macOS (an ordinary child answers for whoever is responsible for this app).
        if responsibleFunction != nil {
            for disclaim in [true, false] {
                guard let child = try? start("/bin/sleep", ["2"], environment: environment, workingDirectory: nil,
                                             stdin: nil, stdout: nil, stderr: nil, disclaim: disclaim) else {
                    f.append("Lancement de /bin/sleep impossible")
                    continue
                }
                usleep(100_000)
                let owner = responsiblePID(child.pid)
                if disclaim && owner != child.pid { f.append("Outil tiers toujours rattaché aux droits de l'app (responsable \(owner ?? -1))") }
                if !disclaim && owner == child.pid { f.append("Outil système détaché des droits de l'app") }
                child.terminate()
                _ = child.waitUntilExit()
            }
        }
        return f
    }

    private static let scriptQueue = DispatchQueue(label: "heartware.applescript")

    /// Runs a command as administrator. macOS shows its own password dialog: the app never sees the password.
    static func runAsAdmin(_ command: String) -> Output {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return appleScript("do shell script \"\(escaped)\" with administrator privileges without altering line endings")
    }

    /// Runs an AppleScript (serialized: NSAppleScript is not thread safe).
    static func appleScript(_ source: String) -> Output {
        if DemoData.isEnabled { return Output(status: -1, out: "", err: DemoData.refusal) }
        return scriptQueue.sync {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? -1
                let message = error[NSAppleScript.errorMessage] as? String ?? "Erreur inconnue"
                return Output(status: Int32(code), out: "", err: code == -128 ? "Opération annulée." : message)
            }
            return Output(status: 0, out: result?.stringValue ?? "", err: "")
        }
    }

    static func exists(_ tool: String) -> Bool { FileManager.default.isExecutableFile(atPath: tool) }
}
