import Darwin
import Foundation

public struct HarvisPOSIXFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let userID: UInt32
    public let groupID: UInt32
    public let mode: UInt32
    public let linkCount: UInt64
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    public var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    public var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    public var isSymbolicLink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
    public var isUserExecutable: Bool { mode & UInt32(S_IXUSR) != 0 }

    public init(
        device: UInt64,
        inode: UInt64,
        userID: UInt32,
        groupID: UInt32,
        mode: UInt32,
        linkCount: UInt64,
        size: UInt64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.userID = userID
        self.groupID = groupID
        self.mode = mode
        self.linkCount = linkCount
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }

    fileprivate init(_ value: stat) {
        self.init(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            userID: value.st_uid,
            groupID: value.st_gid,
            mode: UInt32(value.st_mode),
            linkCount: UInt64(value.st_nlink),
            size: value.st_size >= 0 ? UInt64(value.st_size) : UInt64.max,
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

public enum HarvisPOSIXReadResult: Equatable, Sendable {
    case bytes(Data)
    case endOfFile
    case interrupted
    case failure(errnoCode: Int32)
}

public struct HarvisPOSIXCallError: Error, Equatable, Sendable {
    public let errnoCode: Int32

    public init(errnoCode: Int32) {
        self.errnoCode = errnoCode
    }
}

/// Injectable POSIX seam used by receipt, plist, helper and source-marker readers.
public protocol HarvisPOSIXFileIO: Sendable {
    func openRootDirectory() throws -> Int32
    func openDirectory(relativeTo parentFD: Int32, component: String) throws -> Int32
    func openFile(relativeTo parentFD: Int32, basename: String) throws -> Int32
    func metadata(forFileDescriptor fd: Int32) throws -> HarvisPOSIXFileIdentity
    func metadata(
        relativeTo parentFD: Int32,
        component: String
    ) throws -> HarvisPOSIXFileIdentity
    func read(fileDescriptor fd: Int32, maximumBytes: Int) -> HarvisPOSIXReadResult
    func close(fileDescriptor fd: Int32)
}

public struct HarvisDarwinPOSIXFileIO: HarvisPOSIXFileIO {
    public init() {}

    public func openRootDirectory() throws -> Int32 {
        while true {
            let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd >= 0 { return fd }
            if errno == EINTR { continue }
            throw HarvisPOSIXCallError(errnoCode: errno)
        }
    }

    public func openDirectory(
        relativeTo parentFD: Int32,
        component: String
    ) throws -> Int32 {
        try component.withCString { pointer in
            while true {
                let fd = Darwin.openat(
                    parentFD,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
                if fd >= 0 { return fd }
                if errno == EINTR { continue }
                throw HarvisPOSIXCallError(errnoCode: errno)
            }
        }
    }

    public func openFile(relativeTo parentFD: Int32, basename: String) throws -> Int32 {
        try basename.withCString { pointer in
            while true {
                let fd = Darwin.openat(
                    parentFD,
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
                if fd >= 0 { return fd }
                if errno == EINTR { continue }
                throw HarvisPOSIXCallError(errnoCode: errno)
            }
        }
    }

    public func metadata(forFileDescriptor fd: Int32) throws -> HarvisPOSIXFileIdentity {
        var value = stat()
        while Darwin.fstat(fd, &value) == -1 {
            if errno == EINTR { continue }
            throw HarvisPOSIXCallError(errnoCode: errno)
        }
        return HarvisPOSIXFileIdentity(value)
    }

    public func metadata(
        relativeTo parentFD: Int32,
        component: String
    ) throws -> HarvisPOSIXFileIdentity {
        var value = stat()
        let status = component.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.fstatat(
                    parentFD,
                    pointer,
                    &value,
                    AT_SYMLINK_NOFOLLOW
                )
                if result == 0 { return result }
                if errno == EINTR { continue }
                return result
            }
        }
        guard status == 0 else {
            throw HarvisPOSIXCallError(errnoCode: errno)
        }
        return HarvisPOSIXFileIdentity(value)
    }

    public func read(fileDescriptor fd: Int32, maximumBytes: Int) -> HarvisPOSIXReadResult {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress, maximumBytes)
        }
        if count > 0 {
            return .bytes(Data(bytes.prefix(Int(count))))
        }
        if count == 0 { return .endOfFile }
        if errno == EINTR { return .interrupted }
        return .failure(errnoCode: errno)
    }

    public func close(fileDescriptor fd: Int32) {
        _ = Darwin.close(fd)
    }
}

public struct HarvisBoundedFileRead: Equatable, Sendable {
    public let data: Data
    public let fileIdentity: HarvisPOSIXFileIdentity
    public let directoryChain: [HarvisPOSIXFileIdentity]

    public init(
        data: Data,
        fileIdentity: HarvisPOSIXFileIdentity,
        directoryChain: [HarvisPOSIXFileIdentity]
    ) {
        self.data = data
        self.fileIdentity = fileIdentity
        self.directoryChain = directoryChain
    }
}

public enum HarvisBoundedFileReaderError: Error, Equatable, Sendable {
    case invalidPath
    case missing
    case symlink
    case notRegular
    case empty
    case tooLarge(maximumBytes: Int)
    case unreadable
    case ioFailure
    case changedDuringRead
}

public struct HarvisBoundedFileReader: Sendable {
    private let io: any HarvisPOSIXFileIO

    public init(io: any HarvisPOSIXFileIO = HarvisDarwinPOSIXFileIO()) {
        self.io = io
    }

    public func readFile(
        atCanonicalAbsolutePath path: String,
        maximumBytes: Int,
        requireNonEmpty: Bool = true
    ) throws -> HarvisBoundedFileRead {
        guard maximumBytes > 0,
              let components = Self.absoluteComponents(path),
              let basename = components.last else {
            throw HarvisBoundedFileReaderError.invalidPath
        }
        let directoryComponents = Array(components.dropLast())
        let originalWalk = try openAbsoluteDirectoryChain(directoryComponents)
        defer { closeOwned(originalWalk.fileDescriptors) }

        let output: HarvisBoundedFileRead
        do {
            output = try readLeaf(
                basename: basename,
                parentFD: originalWalk.finalFileDescriptor,
                directoryChain: originalWalk.identities,
                maximumBytes: maximumBytes,
                requireNonEmpty: requireNonEmpty
            )
        } catch {
            throw error
        }

        let rewalk: HarvisDirectoryWalk
        do {
            rewalk = try openAbsoluteDirectoryChain(directoryComponents)
        } catch {
            throw HarvisBoundedFileReaderError.changedDuringRead
        }
        defer { closeOwned(rewalk.fileDescriptors) }
        guard Self.sameDirectoryChain(
            originalWalk.identities,
            rewalk.identities
        ) else {
            throw HarvisBoundedFileReaderError.changedDuringRead
        }
        return output
    }

    public func readFile(
        parentCanonicalPath: String,
        basename: String,
        maximumBytes: Int,
        requireNonEmpty: Bool = true
    ) throws -> HarvisBoundedFileRead {
        guard !basename.isEmpty,
              !basename.contains("/"),
              basename != ".",
              basename != ".." else {
            throw HarvisBoundedFileReaderError.invalidPath
        }
        let separator = parentCanonicalPath == "/" ? "" : "/"
        return try readFile(
            atCanonicalAbsolutePath: parentCanonicalPath + separator + basename,
            maximumBytes: maximumBytes,
            requireNonEmpty: requireNonEmpty
        )
    }

    /// Reads beneath a borrowed directory fd. The caller remains responsible
    /// for validating and retaining the directory's filesystem-root chain.
    public func readFile(
        relativePath: String,
        fromBorrowedDirectoryFileDescriptor rootFD: Int32,
        maximumBytes: Int,
        requireNonEmpty: Bool = true
    ) throws -> HarvisBoundedFileRead {
        guard maximumBytes > 0,
              rootFD >= 0,
              let components = Self.relativeComponents(relativePath),
              let basename = components.last else {
            throw HarvisBoundedFileReaderError.invalidPath
        }
        let directoryComponents = Array(components.dropLast())
        let originalWalk = try openRelativeDirectoryChain(
            directoryComponents,
            rootFD: rootFD
        )
        defer { closeOwned(originalWalk.fileDescriptors) }
        let output = try readLeaf(
            basename: basename,
            parentFD: originalWalk.finalFileDescriptor,
            directoryChain: originalWalk.identities,
            maximumBytes: maximumBytes,
            requireNonEmpty: requireNonEmpty
        )
        let rewalk: HarvisDirectoryWalk
        do {
            rewalk = try openRelativeDirectoryChain(
                directoryComponents,
                rootFD: rootFD
            )
        } catch {
            throw HarvisBoundedFileReaderError.changedDuringRead
        }
        defer { closeOwned(rewalk.fileDescriptors) }
        guard Self.sameDirectoryChain(originalWalk.identities, rewalk.identities) else {
            throw HarvisBoundedFileReaderError.changedDuringRead
        }
        return output
    }

    private func readLeaf(
        basename: String,
        parentFD: Int32,
        directoryChain: [HarvisPOSIXFileIdentity],
        maximumBytes: Int,
        requireNonEmpty: Bool
    ) throws -> HarvisBoundedFileRead {
        let fileFD: Int32
        do {
            fileFD = try io.openFile(relativeTo: parentFD, basename: basename)
        } catch {
            throw mapOpenError(error)
        }
        defer { io.close(fileDescriptor: fileFD) }

        let before = try mappedMetadata(fd: fileFD)
        guard before.isRegularFile else {
            throw HarvisBoundedFileReaderError.notRegular
        }
        if requireNonEmpty, before.size == 0 {
            throw HarvisBoundedFileReaderError.empty
        }
        guard before.size <= UInt64(maximumBytes) else {
            throw HarvisBoundedFileReaderError.tooLarge(maximumBytes: maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(before.size))
        while data.count < Int(before.size) {
            let remaining = Int(before.size) - data.count
            switch io.read(fileDescriptor: fileFD, maximumBytes: min(64 * 1024, remaining)) {
            case let .bytes(chunk):
                guard !chunk.isEmpty, chunk.count <= remaining else {
                    throw HarvisBoundedFileReaderError.changedDuringRead
                }
                data.append(chunk)
            case .endOfFile:
                throw HarvisBoundedFileReaderError.changedDuringRead
            case .interrupted:
                continue
            case .failure:
                throw HarvisBoundedFileReaderError.ioFailure
            }
        }
        while true {
            switch io.read(fileDescriptor: fileFD, maximumBytes: 1) {
            case .bytes:
                throw HarvisBoundedFileReaderError.changedDuringRead
            case .endOfFile:
                break
            case .interrupted:
                continue
            case .failure:
                throw HarvisBoundedFileReaderError.ioFailure
            }
            break
        }

        let after = try mappedMetadata(fd: fileFD)
        let currentEntry: HarvisPOSIXFileIdentity
        do {
            currentEntry = try io.metadata(relativeTo: parentFD, component: basename)
        } catch {
            throw HarvisBoundedFileReaderError.changedDuringRead
        }
        guard before == after,
              after == currentEntry,
              currentEntry.isRegularFile else {
            throw HarvisBoundedFileReaderError.changedDuringRead
        }
        return HarvisBoundedFileRead(
            data: data,
            fileIdentity: after,
            directoryChain: directoryChain
        )
    }

    private func openAbsoluteDirectoryChain(
        _ components: [String]
    ) throws -> HarvisDirectoryWalk {
        let rootFD: Int32
        do {
            rootFD = try io.openRootDirectory()
        } catch {
            throw mapOpenError(error)
        }
        var descriptors = [rootFD]
        do {
            let rootIdentity = try io.metadata(forFileDescriptor: rootFD)
            guard rootIdentity.isDirectory else {
                throw HarvisBoundedFileReaderError.changedDuringRead
            }
            var identities = [rootIdentity]
            var parentFD = rootFD
            for component in components {
                let fd = try io.openDirectory(relativeTo: parentFD, component: component)
                descriptors.append(fd)
                let identity = try io.metadata(forFileDescriptor: fd)
                guard identity.isDirectory else {
                    throw HarvisBoundedFileReaderError.changedDuringRead
                }
                identities.append(identity)
                parentFD = fd
            }
            return HarvisDirectoryWalk(
                fileDescriptors: descriptors,
                identities: identities,
                finalFileDescriptor: parentFD
            )
        } catch {
            closeOwned(descriptors)
            if let readerError = error as? HarvisBoundedFileReaderError {
                throw readerError
            }
            throw mapOpenError(error)
        }
    }

    private func openRelativeDirectoryChain(
        _ components: [String],
        rootFD: Int32
    ) throws -> HarvisDirectoryWalk {
        var descriptors: [Int32] = []
        do {
            let rootIdentity = try io.metadata(forFileDescriptor: rootFD)
            guard rootIdentity.isDirectory else {
                throw HarvisBoundedFileReaderError.invalidPath
            }
            var identities = [rootIdentity]
            var parentFD = rootFD
            for component in components {
                let fd = try io.openDirectory(relativeTo: parentFD, component: component)
                descriptors.append(fd)
                let identity = try io.metadata(forFileDescriptor: fd)
                guard identity.isDirectory else {
                    throw HarvisBoundedFileReaderError.changedDuringRead
                }
                identities.append(identity)
                parentFD = fd
            }
            return HarvisDirectoryWalk(
                fileDescriptors: descriptors,
                identities: identities,
                finalFileDescriptor: parentFD
            )
        } catch {
            closeOwned(descriptors)
            if let readerError = error as? HarvisBoundedFileReaderError {
                throw readerError
            }
            throw mapOpenError(error)
        }
    }

    private func mappedMetadata(fd: Int32) throws -> HarvisPOSIXFileIdentity {
        do {
            return try io.metadata(forFileDescriptor: fd)
        } catch {
            throw HarvisBoundedFileReaderError.ioFailure
        }
    }

    private func mapOpenError(_ error: Error) -> HarvisBoundedFileReaderError {
        guard let callError = error as? HarvisPOSIXCallError else { return .ioFailure }
        switch callError.errnoCode {
        case ENOENT, ENOTDIR:
            return .missing
        case ELOOP:
            return .symlink
        case EACCES, EPERM:
            return .unreadable
        default:
            return .ioFailure
        }
    }

    private func closeOwned(_ descriptors: [Int32]) {
        for fd in descriptors.reversed() {
            io.close(fileDescriptor: fd)
        }
    }

    private static func sameDirectoryChain(
        _ left: [HarvisPOSIXFileIdentity],
        _ right: [HarvisPOSIXFileIdentity]
    ) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { lhs, rhs in
            lhs.device == rhs.device && lhs.inode == rhs.inode
        }
    }

    private static func absoluteComponents(_ path: String) -> [String]? {
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else { return nil }
        let pieces = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return pieces.map(String.init)
    }

    private static func relativeComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return pieces.map(String.init)
    }
}

private struct HarvisDirectoryWalk {
    let fileDescriptors: [Int32]
    let identities: [HarvisPOSIXFileIdentity]
    let finalFileDescriptor: Int32
}
