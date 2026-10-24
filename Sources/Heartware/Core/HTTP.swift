import Foundation

/// The only way the app talks to the Internet. HTTPS only, never in demo mode,
/// and every host contacted is written to the action log. Call it only after a user click
/// or a setting the user turned on (the app promises nothing leaves the Mac otherwise).
enum HTTP {
    enum Failure: LocalizedError {
        case demo, insecure, status(Int), empty

        var errorDescription: String? {
            switch self {
            case .demo: return "Mode démo : aucune connexion réseau."
            case .insecure: return "Adresse refusée : seules les connexions HTTPS sont autorisées."
            case .status(let c): return "Le serveur a répondu avec le code \(c)."
            case .empty: return "Réponse vide."
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Heartware/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (macOS)"]
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return try await send(req)
    }

    static func post(_ url: URL, json: Data, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = json
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return try await send(req)
    }

    /// For slow answers (an AI model thinking before its first byte): five minutes instead of twenty seconds.
    private static let patientSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// Like `send`, but hands back error responses too (their body often explains what went wrong).
    /// `patient` allows up to five minutes of silence from the server.
    static func sendKeepingErrors(_ request: URLRequest, patient: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard !DemoData.isEnabled else { throw Failure.demo }
        guard request.url?.scheme == "https" else { throw Failure.insecure }
        ActionLog.write("RÉSEAU \(request.httpMethod ?? "GET") \(request.url?.host ?? "?")")
        let (data, response) = try await (patient ? patientSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.empty }
        return (data, http)
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !DemoData.isEnabled else { throw Failure.demo }
        guard request.url?.scheme == "https" else { throw Failure.insecure }
        ActionLog.write("RÉSEAU \(request.httpMethod ?? "GET") \(request.url?.host ?? "?")")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.empty }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        return (data, http)
    }

    /// Downloads a big file (an app update) into `folder` under `name`, moved there by `FileOps` (never over another file).
    /// `progress` gets the bytes received and expected (0 when unknown), at most four times a second.
    /// Redirects must stay in HTTPS. Cancelling the calling task stops the transfer.
    static func download(_ url: URL, into folder: URL, name: String,
                         progress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void) async throws -> URL {
        guard !DemoData.isEnabled else { throw Failure.demo }
        guard url.scheme == "https" else { throw Failure.insecure }
        ActionLog.write("RÉSEAU GET \(url.host ?? "?") (téléchargement)")
        let delegate = DownloadDelegate(destination: folder.appendingPathComponent(name), progress: progress)
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = session.configuration.httpAdditionalHeaders
        let downloads = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
        defer { downloads.finishTasksAndInvalidate() }
        let task = downloads.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var saved: Result<URL, Error>?
        private var lastReport = Date.distantPast

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func start(_ c: CheckedContinuation<URL, Error>) {
            lock.lock()
            continuation = c
            lock.unlock()
        }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            lock.lock()
            let due = now.timeIntervalSince(lastReport) >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite
            if due { lastReport = now }
            lock.unlock()
            if due { progress(totalBytesWritten, max(0, totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temporary file goes away when this returns: it is moved right now.
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                saved = .failure(Failure.status(http.statusCode))
                return
            }
            do {
                saved = .success(try FileOps.move(location, to: destination))
            } catch {
                saved = .failure(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { return finish(.failure(error)) }
            finish(saved ?? .failure(Failure.empty))
        }
    }
}
