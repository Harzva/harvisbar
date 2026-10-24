import Darwin
import Foundation
import XCTest
#if !HARVIS_GROUP_CONTROL_STANDALONE
@testable import HarvisBar
#endif

final class HarvisGroupControlServerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/hgc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }
    private func exchange(_ path: String, _ text: String) throws -> Data {
        let fd = try connect(path); defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            if data.contains(10) { break }
        }
        return data
    }
    func testRealSocketRepliesAndProtectsPermissionsAndExclusiveOwnership() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock")
        let first = HarvisGroupControlServer(socketURL: path) { data in data }
        try first.start(); defer { first.stop() }
        let response = try exchange(path.path, "{\"id\":1}\n")
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "{\"id\":1}\n")
        var info = stat(); XCTAssertEqual(lstat(path.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(dir.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let second = HarvisGroupControlServer(socketURL: path) { $0 }
        XCTAssertThrowsError(try second.start()); second.stop()
        XCTAssertEqual(try exchange(path.path, "{\"id\":2}\n"), Data("{\"id\":2}\n".utf8))
    }
    func testStopDoesNotDeleteReplacedPathAndRejectsOversize() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock")
        let server = HarvisGroupControlServer(socketURL: path) { _ in Data("unexpected".utf8) }
        try server.start()
        let fd = try connect(path.path)
        let oversized = Data(repeating: 65, count: HarvisGroupControlServer.maximumMessageBytes + 1)
        oversized.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); if n <= 0 { break }; offset += n }
        }
        var byte: UInt8 = 0; XCTAssertLessThanOrEqual(read(fd, &byte, 1), 0); close(fd)
        XCTAssertEqual(unlink(path.path), 0); try Data("replacement".utf8).write(to: path)
        server.stop(); XCTAssertEqual(try Data(contentsOf: path), Data("replacement".utf8))
    }
    func testRestartReclaimsOwnedStaleSocketButNeverChangesPublicDirectory() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock")
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(result, 0); close(fd)
        let server = HarvisGroupControlServer(socketURL: path) { $0 }
        try server.start(); XCTAssertEqual(try exchange(path.path, "ok\n"), Data("ok\n".utf8))
        server.stop(); try server.start(); server.stop()
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        XCTAssertThrowsError(try server.start())
        var info = stat(); XCTAssertEqual(lstat(dir.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o755)
    }
    func testPipelinedMutationIsRejectedBeforeHandler() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock")
        let server = HarvisGroupControlServer(socketURL: path) { _ in Data("unexpected".utf8) }
        try server.start(); defer { server.stop() }
        XCTAssertTrue(try exchange(path.path, "first\nsecond\n").isEmpty)
    }
    func testRejectsLongPathAndNonSocketWithoutDeletingIt() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let long = HarvisGroupControlServer(socketURL: dir.appendingPathComponent(String(repeating: "x", count: 104))) { $0 }
        XCTAssertThrowsError(try long.start())
        let path = dir.appendingPathComponent("c.sock"); try Data("keep".utf8).write(to: path)
        let server = HarvisGroupControlServer(socketURL: path) { $0 }
        XCTAssertThrowsError(try server.start()); XCTAssertEqual(try Data(contentsOf: path), Data("keep".utf8))
    }
}
