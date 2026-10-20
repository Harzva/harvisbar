import Darwin
import Foundation

struct CodexDesktopProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let homePath: String?
    let userDataDir: String?
}

/// Resolves account identity without retaining or logging process arguments or
/// environment values other than the paths needed to identify the account.
/// The caller must first restrict candidates to the intended desktop app.
enum CodexDesktopIdentity {
    private static let maximumArgumentBytes = 1_048_576

    static func read(
        pid: Int32,
        userRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexDesktopProcessIdentity? {
        guard pid > 0 else { return nil }

        var argumentMaximum: Int32 = 0
        var maximumSize = MemoryLayout<Int32>.size
        var maximumMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maximumMIB, u_int(maximumMIB.count), &argumentMaximum,
                     &maximumSize, nil, 0) == 0,
              argumentMaximum > MemoryLayout<Int32>.size,
              argumentMaximum <= maximumArgumentBytes
        else { return nil }

        var data = Data(count: Int(argumentMaximum))
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        var size = data.count
        var argumentsMIB: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = data.withUnsafeMutableBytes { buffer in
            sysctl(&argumentsMIB, u_int(argumentsMIB.count), buffer.baseAddress,
                   &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size, size <= data.count
        else { return nil }
        data.removeSubrange(size..<data.count)
        return parseProcessArguments(data, pid: pid, userRoot: userRoot)
    }

    static func parseProcessArguments(
        _ data: Data,
        pid: Int32,
        userRoot: URL
    ) -> CodexDesktopProcessIdentity? {
        let headerSize = MemoryLayout<Int32>.size
        guard pid > 0, data.count > headerSize,
              data.count <= maximumArgumentBytes,
              userRoot.isFileURL, userRoot.path.hasPrefix("/")
        else { return nil }
        let count = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }
        // Every argument needs at least a terminating NUL; this also prevents
        // a corrupt argc from causing an unbounded parsing loop.
        guard count > 0, count < data.count - headerSize else { return nil }

        var offset = data.startIndex + headerSize
        func nextField() -> Data.SubSequence? {
            guard offset < data.endIndex,
                  let end = data[offset...].firstIndex(of: 0)
            else { return nil }
            let field = data[offset..<end]
            offset = end + 1
            return field
        }

        guard let executable = nextField(), !executable.isEmpty,
              executable.first == UInt8(ascii: "/")
        else { return nil }
        // KERN_PROCARGS2 pads between the executable path and argv[0].
        while offset < data.endIndex, data[offset] == 0 { offset += 1 }

        var userDataDir: String?
        var awaitingUserDataDir = false
        var isHelper = false
        for index in 0..<Int(count) {
            guard let field = nextField(),
                  let argument = String(data: field, encoding: .utf8),
                  index != 0 || !argument.isEmpty
            else { return nil }
            if awaitingUserDataDir {
                guard userDataDir == nil, isAbsolutePath(argument) else { return nil }
                userDataDir = normalizedHomePath(argument)
                awaitingUserDataDir = false
            } else if argument == "--user-data-dir" {
                guard userDataDir == nil else { return nil }
                awaitingUserDataDir = true
            } else if argument.hasPrefix("--user-data-dir=") {
                let value = String(argument.dropFirst("--user-data-dir=".count))
                guard userDataDir == nil, isAbsolutePath(value) else { return nil }
                userDataDir = normalizedHomePath(value)
            } else if argument == "--type" || argument.hasPrefix("--type=") {
                isHelper = true
            }
        }
        guard !awaitingUserDataDir, !isHelper else { return nil }

        var codexHome: String?
        var processHome: String?
        var hasCodexHome = false
        var hasProcessHome = false
        var hasElectronUserDataDir = false
        while offset < data.endIndex {
            guard let field = nextField() else { return nil }
            if field.isEmpty { continue }
            // Each nonempty environment entry must have a name/value boundary.
            // In particular, a truncated CODEX_HOME override must not silently
            // become an apparent absence and select the default account.
            guard let separator = field.firstIndex(of: UInt8(ascii: "=")),
                  separator != field.startIndex
            else { return nil }
            if field.starts(with: "CODEX_HOME=".utf8) {
                guard !hasCodexHome,
                      let value = String(data: field.dropFirst("CODEX_HOME=".count), encoding: .utf8),
                      isAbsolutePath(value)
                else { return nil }
                hasCodexHome = true
                codexHome = normalizedHomePath(value)
            } else if field.starts(with: "CODEX_ELECTRON_USER_DATA_PATH=".utf8) {
                guard !hasElectronUserDataDir,
                      let value = String(data: field.dropFirst("CODEX_ELECTRON_USER_DATA_PATH=".count), encoding: .utf8),
                      isAbsolutePath(value)
                else { return nil }
                let normalized = normalizedHomePath(value)
                // The desktop app reads this override itself, independently of
                // Electron's command-line switch. A conflict is ambiguous even
                // when the CODEX_HOME happens to identify a known account.
                guard userDataDir == nil || userDataDir == normalized else { return nil }
                hasElectronUserDataDir = true
                userDataDir = normalized
            } else if field.starts(with: "HOME=".utf8) {
                guard !hasProcessHome,
                      let value = String(data: field.dropFirst("HOME=".count), encoding: .utf8)
                else { return nil }
                hasProcessHome = true
                processHome = isAbsolutePath(value) ? normalizedHomePath(value) : nil
            }
        }

        if !hasCodexHome {
            let expectedRoot = normalizedHomePath(userRoot.path)
            let defaultUserDataDir = normalizedHomePath(
                userRoot.appendingPathComponent("Library/Application Support/Codex", isDirectory: true).path
            )
            let usesExpectedRoot = !hasProcessHome || processHome == expectedRoot
            let usesDefaultUserDataDir = userDataDir == nil || userDataDir == defaultUserDataDir
            if usesExpectedRoot && usesDefaultUserDataDir {
                codexHome = normalizedHomePath(userRoot.appendingPathComponent(".codex", isDirectory: true).path)
            }
        }

        return CodexDesktopProcessIdentity(pid: pid, homePath: codexHome, userDataDir: userDataDir)
    }

    static func normalizedHomePath(_ path: String) -> String {
        // Foundation only resolves a symlink when the complete path exists.
        // Resolve the existing prefix too, so a newly selected user-data-dir
        // beneath a symlink has the same identity before and after creation.
        var prefix = URL(fileURLWithPath: path, isDirectory: true)
        var suffix: [String] = []
        while prefix.path != "/", !FileManager.default.fileExists(atPath: prefix.path) {
            suffix.append(prefix.lastPathComponent)
            prefix.deleteLastPathComponent()
        }
        var resolved = prefix.resolvingSymlinksInPath()
        for component in suffix.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.standardizedFileURL.path
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count < Int(PATH_MAX) && !value.utf8.contains(0)
    }
}
