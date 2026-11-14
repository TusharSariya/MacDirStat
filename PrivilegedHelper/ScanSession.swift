import Foundation
import Darwin

final class ScanSession: NSObject, ElevatedScannerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var finished = false
    private var latest: ScanProgress?
    private var result: Data?
    private var failure: String?
    private var task: Task<Void, Never>?

    func startScan(path: String, authorization: Data, reply: @escaping @Sendable (String?) -> Void) {
        let allowed = lock.withLock { () -> Bool in
            guard !started, !stopped else { return false }
            started = true
            return true
        }
        guard allowed else { reply("This connection already started a scan."); return }
        do {
            let root = try ElevatedConfiguration.validate(path: path)
            try ScanAuthorization.verify(authorization)
            let worker = Task.detached(priority: .userInitiated) { [self] in
                do {
                    let snapshot = try DiskScanner.scan(root) { [self] value in
                        lock.withLock { latest = value }
                    }
                    try Task.checkCancellation()
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    let encoded = try encoder.encode(ElevatedUpdate(progress: nil, snapshot: snapshot))
                    try Task.checkCancellation()
                    lock.withLock {
                        if !stopped { result = encoded; finished = true }
                    }
                } catch {
                    lock.withLock {
                        failure = error is CancellationError ? "Scan cancelled." : error.localizedDescription
                        finished = true
                    }
                }
            }
            lock.withLock {
                task = worker
                if stopped { worker.cancel() }
            }
            reply(nil)
        } catch {
            lock.withLock { failure = error.localizedDescription; finished = true }
            reply(error.localizedDescription)
        }
    }

    func poll(reply: @escaping @Sendable (Data?, Bool, String?) -> Void) {
        let state = lock.withLock { (result, finished, failure, latest, started) }
        if !state.4 { reply(nil, true, "No scan has been requested."); return }
        if state.1 { reply(state.0, true, state.2); return }
        let data = try? PropertyListEncoder().encode(ElevatedUpdate(progress: state.3, snapshot: nil))
        reply(data, false, nil)
    }

    func stop() {
        lock.withLock {
            stopped = true
            task?.cancel()
            result = nil
            latest = nil
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let clientRequirement: String
    init(clientRequirement: String) { self.clientRequirement = clientRequirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = ScanSession()
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: ElevatedScannerProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.stop() }
        connection.interruptionHandler = { session.stop() }
        connection.resume()
        return true
    }
}
