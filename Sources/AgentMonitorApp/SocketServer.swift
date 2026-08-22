import Darwin
import Foundation
import AgentMonitorShared

final class SocketServer: @unchecked Sendable {
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.agentmonitor.socket")
    private let handler: @Sendable (MonitorEvent) -> Void

    init(handler: @escaping @Sendable (MonitorEvent) -> Void) {
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(at: AppPaths.baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.baseDirectory.path)
        unlink(AppPaths.socketURL.path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ServerError.socketCreation }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(AppPaths.socketURL.path.utf8CString)
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: utf8.map(UInt8.init(bitPattern:)))
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard result == 0, listen(listener, 16) == 0 else { throw ServerError.bind(errno) }
        chmod(AppPaths.socketURL.path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [listener] in close(listener) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(AppPaths.socketURL.path)
    }

    private func acceptConnection() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        queue.async { [handler] in
            defer { close(client) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while data.count <= MonitorEvent.maximumWireSize {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                if let newline = buffer.prefix(count).firstIndex(of: 0x0A) {
                    data.append(contentsOf: buffer.prefix(newline))
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            do {
                guard data.count <= MonitorEvent.maximumWireSize else { throw MonitorEventError.messageTooLarge }
                let event = try JSONDecoder.monitorDecoder.decode(MonitorEvent.self, from: data)
                try event.validate()
                handler(event)
                _ = Darwin.write(client, "ok\n", 3)
            } catch {
                _ = Darwin.write(client, "error\n", 6)
            }
        }
    }

    enum ServerError: LocalizedError {
        case socketCreation, pathTooLong, bind(Int32)
        var errorDescription: String? {
            switch self {
            case .socketCreation: "Could not create the event socket"
            case .pathTooLong: "The event socket path is too long"
            case let .bind(code): "Could not listen for events (errno \(code))"
            }
        }
    }
}
