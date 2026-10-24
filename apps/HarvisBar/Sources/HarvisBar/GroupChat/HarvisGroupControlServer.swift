import Darwin
import Foundation

/// One bounded JSON-RPC line per same-user connection. No business state lives here.
final class HarvisGroupControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data
    static let maximumMessageBytes = 1_048_576
    private let socketURL: URL
    private let handler: Handler
    private let mutex = NSLock()
    private var listener: Int32 = -1
    private var lockFile: Int32 = -1
    private var generation: UUID?
    private var identity: (dev_t, ino_t)?
    private var activeClients = 0

    init(socketURL: URL = HarvisGroupControlServer.defaultSocketURL(), handler: @escaping Handler) {
        self.socketURL = socketURL; self.handler = handler
    }
    static func defaultSocketURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["HARVIS_GROUP_SOCKET"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarvisBar/GroupChat/control.sock")
    }
    func start() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard listener < 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ServerError("Group socket path exceeds the macOS limit (103 UTF-8 bytes). Set HARVIS_GROUP_SOCKET to a shorter private path.")
        }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw ServerError("Group socket directory must be owned by this user and must not be a symlink.")
        }
        guard info.st_mode & 0o777 == 0o700 else { throw ServerError("Group socket directory must already be private (0700); choose a dedicated directory.") }
        let ownedLock = open(socketURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard ownedLock >= 0 else { throw ServerError("Cannot open group socket ownership lock.") }
        var lockInfo = stat()
        guard fstat(ownedLock, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              flock(ownedLock, LOCK_EX | LOCK_NB) == 0 else {
            close(ownedLock); throw ServerError("Another group server owns this socket.")
        }
        _ = fchmod(ownedLock, 0o600)
        var success = false
        defer { if !success { close(ownedLock) } }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError("Cannot create group control socket.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        defer { if !success { close(fd) } }
        var existing = stat()
        if lstat(socketURL.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else { throw ServerError("Group socket path is not an owned socket.") }
            let result = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result < 0, errno == ECONNREFUSED else { throw ServerError("Existing group socket is active or cannot be safely replaced.") }
            guard unlink(socketURL.path) == 0 else { throw ServerError("Cannot remove stale group socket.") }
        }
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw ServerError("Cannot bind group control socket.") }
        var bound = stat()
        guard lstat(socketURL.path, &bound) == 0 else { throw ServerError("Cannot inspect bound group socket.") }
        guard chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0 else {
            _ = unlink(socketURL.path); throw ServerError("Cannot protect or listen on group socket.")
        }
        let acceptFD = dup(fd)
        guard acceptFD >= 0 else { _ = unlink(socketURL.path); throw ServerError("Cannot retain group listener.") }
        _ = fcntl(acceptFD, F_SETFD, FD_CLOEXEC)
        listener = fd; lockFile = ownedLock; identity = (bound.st_dev, bound.st_ino)
        let token = UUID(); generation = token; success = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { close(acceptFD) }
            self?.acceptClients(fd: acceptFD, generation: token)
        }
    }
    func stop() {
        mutex.lock(); defer { mutex.unlock() }
        generation = nil
        if listener >= 0 { _ = shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        if let identity {
            var info = stat()
            if lstat(socketURL.path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { _ = unlink(socketURL.path) }
        }
        identity = nil
        // Never unlink the lock inode: that could allow two independent locks.
        if lockFile >= 0 { close(lockFile); lockFile = -1 }
    }
    deinit { stop() }
    private func acceptClients(fd: Int32, generation token: UUID) {
        while true {
            mutex.lock(); let running = generation == token; mutex.unlock()
            guard running else { return }
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var uid: uid_t = 0; var gid: gid_t = 0
            mutex.lock()
            let permitted = generation == token && activeClients < 16 && getpeereid(client, &uid, &gid) == 0 && uid == getuid()
            if permitted { activeClients += 1 }
            mutex.unlock()
            guard permitted else { close(client); continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { close(client); self?.finishedClient() }
                self?.serve(client, generation: token)
            }
        }
    }
    private func finishedClient() { mutex.lock(); activeClients -= 1; mutex.unlock() }
    private func serve(_ fd: Int32, generation token: UUID) {
        var duration = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &duration, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &duration, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var request = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while request.count <= Self.maximumMessageBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            var receiveTimeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            let count = read(fd, &buffer, min(buffer.count, Self.maximumMessageBytes + 1 - request.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
            if let end = request.firstIndex(of: 10) {
                guard end <= Self.maximumMessageBytes, request[(end + 1)...].allSatisfy({ $0 == 10 || $0 == 13 || $0 == 32 }) else { return }
                request = request.prefix(end); break
            }
        }
        guard request.count <= Self.maximumMessageBytes else { return }
        mutex.lock(); let running = generation == token; mutex.unlock()
        guard running else { return }
        let response = ResponseBox(); let signal = DispatchSemaphore(value: 0); let handler = self.handler
        let line = request
        Task { response.set(await handler(line)); signal.signal() }
        guard signal.wait(timeout: .now() + 30) == .success, var bytes = response.get(), bytes.count <= Self.maximumMessageBytes else { return }
        bytes.append(10)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }; offset += count
            }
        }
    }
    struct ServerError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    private final class ResponseBox: @unchecked Sendable {
        private let mutex = NSLock(); private var value: Data?
        func set(_ value: Data) { mutex.lock(); self.value = value; mutex.unlock() }
        func get() -> Data? { mutex.lock(); defer { mutex.unlock() }; return value }
    }
}
