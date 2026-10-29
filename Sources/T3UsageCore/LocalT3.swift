import Foundation
import Darwin

public struct RuntimeEndpoint: Sendable {
    public let webSocketURL: URL
    public static func decode(_ data: Data) throws -> RuntimeEndpoint {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = j["host"] as? String, ["127.0.0.1", "localhost", "::1"].contains(host),
              let portNumber = j["port"] as? NSNumber, CFGetTypeID(portNumber) != CFBooleanGetTypeID(),
              portNumber.doubleValue.rounded() == portNumber.doubleValue,
              (1...65535).contains(portNumber.intValue),
              let origin = j["origin"] as? String, let url = URLComponents(string: origin),
              url.scheme == "http", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port == portNumber.intValue,
              url.host == host || (host == "::1" && url.host == "[::1]") else { throw UsageError.unsafeEndpoint }
        var ws = url; ws.scheme = "ws"; ws.path = "/ws"
        ws.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        guard let endpoint = ws.url else { throw UsageError.unsafeEndpoint }
        return RuntimeEndpoint(webSocketURL: endpoint)
    }
}
import CoreFoundation

private struct IssuedSession: Decodable {
    let sessionId: String
    let token: String
    let method: String
    let scopes: [String]
    let expiresAt: String
}

/// Runs only the existing T3 CLI's scoped session issue/revoke commands; never invokes a shell.
/// Raw stdout is kept in memory; stderr is discarded so upstream diagnostics cannot leak secrets.
private enum LocalCLI {
    static func run(home: URL, arguments: [String]) throws -> Data {
        let cli = home.appendingPathComponent(".t3/bin/t3")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw UsageError.cliMissing }
        let process = Process(); let pipe = Pipe()
        process.executableURL = cli
        process.arguments = arguments + ["--base-dir", home.appendingPathComponent(".t3").path, "--log-level", "none"]
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "T3CODE_HOME": home.appendingPathComponent(".t3").path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        do { try process.run() } catch { throw UsageError.cliFailed }
        // T3's issue JSON is small. Drain concurrently so the child cannot fill the pipe.
        let output = CapturedOutput()
        let readSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let bytes = pipe.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                output.append(bytes)
            }
            readSignal.signal()
        }
        if exitSignal.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // Let the reader observe EOF; closing its FileHandle concurrently can raise an exception.
            _ = readSignal.wait(timeout: .now() + 1)
            throw UsageError.timeout
        }
        guard readSignal.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0,
              let data = output.value else { throw UsageError.cliFailed }
        return data
    }
}
private final class CapturedOutput: @unchecked Sendable {
    let lock = NSLock(); var data = Data(); var overflow = false
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if data.count + bytes.count <= 262144 { data.append(bytes) } else { overflow = true } }
    var value: Data? { lock.lock(); defer { lock.unlock() }; return overflow ? nil : data }
}

/// A refresh is a short, scoped read session. It ends/revokes before returning.
/// No provider refresh, provider login, model inference, database or conversation reads.
public struct LocalT3Client: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    public func readSnapshot() async throws -> UsageSnapshot {
        let metadata = home.appendingPathComponent(".t3/userdata/server-runtime.json")
        guard let data = try? Data(contentsOf: metadata) else { throw UsageError.runtimeMissing }
        let endpoint = try RuntimeEndpoint.decode(data)
        let issuedData = try await Task.detached(priority: .utility) {
            try LocalCLI.run(home: home, arguments: ["auth", "session", "issue", "--scope", "orchestration:read", "--ttl", "5m", "--label", "T3 Usage read-only", "--subject", "t3-usage-menubar", "--json"])
        }.value
        guard let issued = try? JSONDecoder().decode(IssuedSession.self, from: issuedData),
              issued.method == "bearer-access-token", issued.scopes == ["orchestration:read"],
              !issued.token.isEmpty, !issued.sessionId.isEmpty, Dates.parse(issued.expiresAt) != nil else { throw UsageError.cliFailed }
        let result: Result<UsageSnapshot, Error>
        do { result = .success(try await fetch(endpoint: endpoint, token: issued.token)) }
        catch { result = .failure(error) }
        // Session id is not a bearer credential. Revocation output is always discarded.
        let revoked = await Task.detached(priority: .utility) {
            (try? LocalCLI.run(home: home, arguments: ["auth", "session", "revoke", issued.sessionId])) != nil
        }.value
        // A failed revoke is bounded by the CLI-issued 5 minute TTL. It never makes data fresher.
        var snapshot = try result.get()
        snapshot.readSessionRevoked = revoked
        return snapshot
    }
    private func fetch(endpoint: RuntimeEndpoint, token: String) async throws -> UsageSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 18
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: endpoint.webSocketURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        do {
            return try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await Self.read(socket: socket)
                    } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
                }
                group.addTask { try await Task.sleep(nanoseconds: 18_000_000_000); throw UsageError.timeout }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as UsageError { throw error }
        catch { throw UsageError.connection }
    }
    private static func send(_ value: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private static func read(socket: URLSessionWebSocketTask) async throws -> UsageSnapshot {
        try await send(["_tag": "Request", "id": "1", "tag": "subscribeServerConfig", "payload": ["usageLimitSources": true, "workspaceSnapshotsOnDemand": true], "headers": []], socket: socket)
        var config: [String: Any]?; var sources: [[String: Any]]?
        // Bounded event count in addition to the wall-clock deadline. All unrelated config fields are discarded.
        for _ in 0..<64 {
            let message = try await socket.receive()
            let bytes: Data
            switch message { case .data(let d): bytes = d; case .string(let s): bytes = Data(s.utf8); @unknown default: throw UsageError.invalidResponse }
            let object = try JSONSerialization.jsonObject(with: bytes)
            let messages: [[String: Any]]
            if let array = object as? [[String: Any]] { messages = array }
            else if let single = object as? [String: Any] { messages = [single] }
            else { throw UsageError.invalidResponse }
            for m in messages {
                if m["_tag"] as? String == "Ping" { try await send(["_tag": "Pong"], socket: socket); continue }
                if ["Exit", "Defect"].contains(m["_tag"] as? String ?? "") { throw UsageError.unauthorized }
                guard m["_tag"] as? String == "Chunk", m["requestId"] as? String == "1", let values = m["values"] as? [[String: Any]] else { continue }
                for value in values {
                    switch value["type"] as? String {
                    case "snapshot": config = value["config"] as? [String: Any]
                    case "usageLimitSourcesUpdated": sources = (value["payload"] as? [String: Any])?["sources"] as? [[String: Any]]
                    case "providerStatuses":
                        if let providers = (value["payload"] as? [String: Any])?["providers"] { config?["providers"] = providers }
                    default: break
                    }
                }
                try await send(["_tag": "Ack", "requestId": "1"], socket: socket)
            }
            if let config, let sources { return try SnapshotParser.parse(config: config, sources: sources) }
        }
        throw UsageError.invalidResponse
    }
}

/// A local endpoint must never redirect a scoped credential to another host.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
