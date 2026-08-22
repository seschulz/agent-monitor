import Darwin
import Foundation
import AgentMonitorShared

enum SocketClient {
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMonitor/events.sock").path
    }

    static func send(_ event: MonitorEvent) throws {
        try event.validate()
        var payload = try JSONEncoder.monitorEncoder.encode(event)
        guard payload.count < MonitorEvent.maximumWireSize else { throw MonitorEventError.messageTooLarge }
        payload.append(0x0A)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.socketCreation }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8CString)
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ClientError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: utf8.map(UInt8.init(bitPattern:)))
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) }
        }
        guard connected == 0 else { throw ClientError.connection(errno) }
        let written = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, payload.count) }
        guard written == payload.count else { throw ClientError.writeFailed }
        var reply = [UInt8](repeating: 0, count: 16)
        let count = read(descriptor, &reply, reply.count)
        guard count > 0, String(bytes: reply.prefix(count), encoding: .utf8)?.hasPrefix("ok") == true else {
            throw ClientError.rejected
        }
    }

    enum ClientError: LocalizedError {
        case socketCreation, pathTooLong, connection(Int32), writeFailed, rejected
        var errorDescription: String? {
            switch self {
            case .socketCreation: "Could not create local socket"
            case .pathTooLong: "Socket path is too long"
            case let .connection(code): "Could not reach Agent Monitor (errno \(code))"
            case .writeFailed: "Could not send event"
            case .rejected: "Agent Monitor rejected the event"
            }
        }
    }
}
