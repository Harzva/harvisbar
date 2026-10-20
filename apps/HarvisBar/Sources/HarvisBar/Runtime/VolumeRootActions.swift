import AppKit
import Foundation

@MainActor
struct VolumeRootActions {
    typealias PathWriter = (String) -> Bool
    typealias URLOpener = (URL) -> Bool
    typealias URLRevealer = (URL) -> Bool

    private let pathWriter: PathWriter
    private let urlOpener: URLOpener
    private let urlRevealer: URLRevealer

    init(
        pathWriter: @escaping PathWriter,
        urlOpener: @escaping URLOpener,
        urlRevealer: @escaping URLRevealer
    ) {
        self.pathWriter = pathWriter
        self.urlOpener = urlOpener
        self.urlRevealer = urlRevealer
    }

    @discardableResult
    func copyRootPath(for disk: DiskInfo) -> Bool {
        pathWriter(disk.volumeURL.path)
    }

    @discardableResult
    func openRoot(for disk: DiskInfo) -> Bool {
        urlOpener(disk.volumeURL)
    }

    @discardableResult
    func revealRoot(for disk: DiskInfo) -> Bool {
        urlRevealer(disk.volumeURL)
    }

    static func accessibilityIdentifierComponent(for disk: DiskInfo) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in disk.volumeURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let kind = disk.isInternal == true ? "internal" : "external"
        return "\(kind)-\(String(format: "%016llx", hash))"
    }

    static let live = VolumeRootActions(
        pathWriter: { path in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(path, forType: .string)
        },
        urlOpener: { url in
            NSWorkspace.shared.open(url)
        },
        urlRevealer: { url in
            NSWorkspace.shared.selectFile(
                url.path,
                inFileViewerRootedAtPath: ""
            )
        }
    )
}
