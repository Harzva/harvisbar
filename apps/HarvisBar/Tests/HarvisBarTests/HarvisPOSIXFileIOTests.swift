import Darwin
import Foundation
import HarvisVersionCore
import XCTest

final class HarvisPOSIXFileIOTests: XCTestCase {
    func testReaderAcceptsExactLimitAndRetriesEINTR() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appendingPathComponent("receipt.json")
        try Data(repeating: 0x61, count: 32).write(to: file)
        let io = InterruptOnceFileIO()

        let result = try HarvisBoundedFileReader(io: io).readFile(
            atCanonicalAbsolutePath: canonical(file),
            maximumBytes: 32
        )

        XCTAssertEqual(result.data, Data(repeating: 0x61, count: 32))
        XCTAssertEqual(result.fileIdentity.size, 32)
        XCTAssertTrue(result.fileIdentity.isRegularFile)
        XCTAssertGreaterThanOrEqual(result.directoryChain.count, 2)
        XCTAssertEqual(io.interruptionCount, 1)
    }

    func testReaderRejectsEmptyOversizeSymlinkAndFIFO() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let empty = fixture.directory.appendingPathComponent("empty")
        let oversize = fixture.directory.appendingPathComponent("oversize")
        let link = fixture.directory.appendingPathComponent("link")
        let fifo = fixture.directory.appendingPathComponent("fifo")
        try Data().write(to: empty)
        try Data(repeating: 0x78, count: 17).write(to: oversize)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oversize)
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let reader = HarvisBoundedFileReader()

        assertReaderError(.empty) {
            _ = try reader.readFile(atCanonicalAbsolutePath: canonical(empty), maximumBytes: 16)
        }
        assertReaderError(.tooLarge(maximumBytes: 16)) {
            _ = try reader.readFile(atCanonicalAbsolutePath: canonical(oversize), maximumBytes: 16)
        }
        assertReaderError(.symlink) {
            _ = try reader.readFile(atCanonicalAbsolutePath: canonicalParent(link), maximumBytes: 16)
        }
        assertReaderError(.notRegular) {
            _ = try reader.readFile(atCanonicalAbsolutePath: canonicalParent(fifo), maximumBytes: 16)
        }
    }

    func testReaderDetectsAtomicLeafReplacementAfterFirstChunk() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appendingPathComponent("helper")
        let replacement = fixture.directory.appendingPathComponent("helper.next")
        try Data(repeating: 0x61, count: 96 * 1024).write(to: file)
        try Data(repeating: 0x62, count: 96 * 1024).write(to: replacement)
        let canonicalFile = canonical(file)
        let canonicalReplacement = canonical(replacement)
        let io = ReplaceAfterFirstChunkFileIO(
            originalPath: canonicalFile,
            replacementPath: canonicalReplacement
        )

        assertReaderError(.changedDuringRead) {
            _ = try HarvisBoundedFileReader(io: io).readFile(
                atCanonicalAbsolutePath: canonicalFile,
                maximumBytes: 128 * 1024
            )
        }
        XCTAssertTrue(io.didReplace)
    }

    func testBorrowedDirectoryFDReadDoesNotTakeOwnership() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let nested = fixture.directory.appendingPathComponent("apps/HarvisBar")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let marker = nested.appendingPathComponent("Package.swift")
        try Data("marker".utf8).write(to: marker)
        let rootPath = canonical(fixture.directory)
        let fd = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }

        let result = try HarvisBoundedFileReader().readFile(
            relativePath: "apps/HarvisBar/Package.swift",
            fromBorrowedDirectoryFileDescriptor: fd,
            maximumBytes: 64
        )
        XCTAssertEqual(result.data, Data("marker".utf8))
        XCTAssertNotEqual(Darwin.fcntl(fd, F_GETFD), -1, "Reader must borrow, not close, rootFD")
    }

    private func makeFixture() throws -> (directory: URL, canonicalPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-file-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, canonical(directory))
    }

    private func canonical(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        precondition(Darwin.realpath(url.path, &buffer) != nil)
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func canonicalParent(_ url: URL) -> String {
        canonical(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
    }

    private func assertReaderError(
        _ expected: HarvisBoundedFileReaderError,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? HarvisBoundedFileReaderError, expected)
        }
    }
}

private final class InterruptOnceFileIO: HarvisPOSIXFileIO, @unchecked Sendable {
    private let base = HarvisDarwinPOSIXFileIO()
    private let lock = NSLock()
    private var interrupted = false

    var interruptionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return interrupted ? 1 : 0
    }

    func openRootDirectory() throws -> Int32 { try base.openRootDirectory() }
    func openDirectory(relativeTo parentFD: Int32, component: String) throws -> Int32 {
        return try base.openDirectory(relativeTo: parentFD, component: component)
    }
    func openFile(relativeTo parentFD: Int32, basename: String) throws -> Int32 {
        try base.openFile(relativeTo: parentFD, basename: basename)
    }
    func metadata(forFileDescriptor fd: Int32) throws -> HarvisPOSIXFileIdentity {
        try base.metadata(forFileDescriptor: fd)
    }
    func metadata(relativeTo parentFD: Int32, component: String) throws -> HarvisPOSIXFileIdentity {
        try base.metadata(relativeTo: parentFD, component: component)
    }
    func read(fileDescriptor fd: Int32, maximumBytes: Int) -> HarvisPOSIXReadResult {
        lock.lock()
        if !interrupted {
            interrupted = true
            lock.unlock()
            return .interrupted
        }
        lock.unlock()
        return base.read(fileDescriptor: fd, maximumBytes: maximumBytes)
    }
    func close(fileDescriptor fd: Int32) { base.close(fileDescriptor: fd) }
}

private final class ReplaceAfterFirstChunkFileIO: HarvisPOSIXFileIO, @unchecked Sendable {
    private let base = HarvisDarwinPOSIXFileIO()
    private let originalPath: String
    private let replacementPath: String
    private let lock = NSLock()
    private var replaced = false

    init(originalPath: String, replacementPath: String) {
        self.originalPath = originalPath
        self.replacementPath = replacementPath
    }

    var didReplace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return replaced
    }

    func openRootDirectory() throws -> Int32 { try base.openRootDirectory() }
    func openDirectory(relativeTo parentFD: Int32, component: String) throws -> Int32 {
        try base.openDirectory(relativeTo: parentFD, component: component)
    }
    func openFile(relativeTo parentFD: Int32, basename: String) throws -> Int32 {
        try base.openFile(relativeTo: parentFD, basename: basename)
    }
    func metadata(forFileDescriptor fd: Int32) throws -> HarvisPOSIXFileIdentity {
        try base.metadata(forFileDescriptor: fd)
    }
    func metadata(relativeTo parentFD: Int32, component: String) throws -> HarvisPOSIXFileIdentity {
        try base.metadata(relativeTo: parentFD, component: component)
    }
    func read(fileDescriptor fd: Int32, maximumBytes: Int) -> HarvisPOSIXReadResult {
        let result = base.read(fileDescriptor: fd, maximumBytes: maximumBytes)
        guard case .bytes = result else { return result }
        lock.lock()
        if !replaced {
            replaced = Darwin.rename(replacementPath, originalPath) == 0
        }
        lock.unlock()
        return result
    }
    func close(fileDescriptor fd: Int32) { base.close(fileDescriptor: fd) }
}
