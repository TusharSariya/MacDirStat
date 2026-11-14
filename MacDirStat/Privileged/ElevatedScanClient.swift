import Foundation

final class RPCReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, any Error>) {
        let pending = lock.withLock {
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume(with: result)
    }
}

final class ElevatedScanClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var invalidated = false

    init() throws {
        connection = NSXPCConnection(machServiceName: ElevatedConfiguration.helperIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ElevatedScannerProtocol.self)
        connection.setCodeSigningRequirement(try PeerSigning.requirement(identifier: ElevatedConfiguration.helperIdentifier))
        connection.resume()
    }

    func cancel() {
        lock.withLock { invalidated = true }
        connection.invalidate()
    }

    private func request<Value: Sendable>(
        _ send: @escaping @Sendable (any ElevatedScannerProtocol, RPCReply<Value>) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = RPCReply(continuation)
            lock.withLock {
                guard !invalidated else { reply.finish(.failure(CancellationError())); return }
                connection.invalidationHandler = {
                    reply.finish(.failure(ElevatedError.message("The administrator scanner disconnected. Check its approval in System Settings and retry.")))
                }
                connection.interruptionHandler = {
                    reply.finish(.failure(ElevatedError.message("The administrator scanner was interrupted.")))
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    reply.finish(.failure(error))
                }) as? any ElevatedScannerProtocol else {
                    reply.finish(.failure(ElevatedError.message("Could not connect to the administrator scanner.")))
                    return
                }
                send(proxy, reply)
            }
        }
    }

    static func scan(_ url: URL, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanSnapshot {
        _ = try ElevatedConfiguration.validate(path: url.path)
        // Inspect signatures before asking the user to authenticate.
        let client = try ElevatedScanClient()
        defer { client.cancel() }
        return try await withTaskCancellationHandler {
            let grant = try await Task.detached(priority: .userInitiated) { try ScanAuthorization.request() }.value
            defer { withExtendedLifetime(grant) {} }
            try Task.checkCancellation()
            let _: Bool = try await client.request { proxy, reply in
                proxy.startScan(path: url.path, authorization: grant.externalForm) { message in
                    if let message { reply.finish(.failure(ElevatedError.message(message))) }
                    else { reply.finish(.success(true)) }
                }
            }
            while true {
                try Task.checkCancellation()
                let (data, finished, failure): (Data?, Bool, String?) = try await client.request { proxy, reply in
                    proxy.poll { data, finished, failure in reply.finish(.success((data, finished, failure))) }
                }
                if let failure { throw ElevatedError.message(failure) }
                if let data {
                    let update = try PropertyListDecoder().decode(ElevatedUpdate.self, from: data)
                    if let value = update.progress { progress(value) }
                    if let snapshot = update.snapshot { return snapshot }
                }
                if finished { throw ElevatedError.message("The administrator scanner returned no result.") }
                try await Task.sleep(for: .milliseconds(150))
            }
        } onCancel: { client.cancel() }
    }
}
