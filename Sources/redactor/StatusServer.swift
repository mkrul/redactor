import Darwin
import Foundation

enum StatusClient {
    static func run(_ command: String) -> Never {
        if let reply = request(command) {
            FileHandle.standardOutput.write(Data(reply.utf8))
            exit(0)
        }
        FileHandle.standardOutput.write(Data("state: not running\n".utf8))
        exit(1)
    }

    private static func request(_ command: String) -> String? {
        let path = RedactorPaths.socketFile.path
        guard path.utf8.count < 104 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_un()
        guard configureUnixAddress(path, &address) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 { return nil }
        let line = command + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var collected = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waited = poll(&item, 1, 200)
            if waited < 0 {
                if errno == EINTR { continue }
                break
            }
            if waited == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            collected.append(buffer, count: count)
            if let text = String(data: collected, encoding: .utf8), text.contains("\n\n") { break }
        }
        guard let text = String(data: collected, encoding: .utf8) else { return nil }
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            lines.append(String(line))
        }
        if lines.isEmpty { return nil }
        return lines.joined(separator: "\n") + "\n"
    }
}

final class StatusServer {
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "redactor.status")
    private weak var agent: Agent?

    func start(agent: Agent) -> Bool {
        self.agent = agent
        RedactorPaths.ensure(RedactorPaths.supportDirectory)
        let path = RedactorPaths.socketFile.path
        guard path.utf8.count < 104 else { return false }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_un()
        guard configureUnixAddress(path, &address) else {
            close(fd)
            return false
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound != 0 || listen(fd, 16) != 0 {
            close(fd)
            return false
        }
        chmod(path, 0o600)
        listenFD = fd
        queue.async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }
        unlink(RedactorPaths.socketFile.path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if listenFD < 0 { return }
                usleep(50_000)
                continue
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64)
        var count = 0
        while count < buffer.count {
            let readCount = read(client, &buffer[count], buffer.count - count)
            if readCount < 0 {
                if errno == EINTR { continue }
                return
            }
            if readCount == 0 { break }
            count += readCount
            if buffer[0..<count].contains(10 as UInt8) { break }
        }
        let line = String(bytes: buffer[0..<count], encoding: .utf8) ?? ""
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = DispatchQueue.main.sync {
            self.agent?.handleCommand(command) ?? ""
        }
        _ = reply.withCString { write(client, $0, strlen($0)) }
    }
}

private func configureUnixAddress(_ path: String, _ address: inout sockaddr_un) -> Bool {
    let bytes = Array(path.utf8)
    guard bytes.count < 104 else { return false }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: 104) { raw in
            for index in 0..<104 { raw[index] = 0 }
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            return true
        }
    }
}
