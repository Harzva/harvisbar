import CoreFoundation
import Foundation

/// The single persisted authority for the user-selected Harvis source root.
///
/// The production implementation intentionally uses a fixed application ID,
/// key, user and host scope. It must not follow the currently running bundle
/// identifier (the UI-test App has a different identity), nor inherit a
/// process-specific `UserDefaults.standard` suite.
public protocol HarvisSourcePreferenceStoring {
    func readSourceRoot() throws -> String?
    func writeSourceRoot(_ sourceRoot: String?) throws
}

public enum HarvisSourcePreferenceError: Error, Equatable, Sendable {
    case synchronizationFailed
    case invalidStoredValue
}

public struct HarvisSourcePreferenceStore: HarvisSourcePreferenceStoring, Sendable {
    public static let applicationID = "local.harzva.harvisbar"
    public static let sourceRootKey = "harvisBar.harvisSourceRoot"

    private let applicationID: String
    private let key: String

    /// Creates the fixed production store.
    public init() {
        applicationID = Self.applicationID
        key = Self.sourceRootKey
    }

    /// Creates an isolated store for deterministic tests. Production code must
    /// use the no-argument initializer so the authority cannot drift with a
    /// bundle identifier or environment value.
    init(testApplicationID: String, key: String = HarvisSourcePreferenceStore.sourceRootKey) {
        precondition(!testApplicationID.isEmpty)
        precondition(!key.isEmpty)
        applicationID = testApplicationID
        self.key = key
    }

    public func readSourceRoot() throws -> String? {
        guard synchronize() else {
            throw HarvisSourcePreferenceError.synchronizationFailed
        }
        guard let value = CFPreferencesCopyValue(
            key as CFString,
            applicationID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            return nil
        }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String else {
            throw HarvisSourcePreferenceError.invalidStoredValue
        }
        // Return the raw string byte-for-byte. Validation belongs to the source
        // inspector; silently trimming or replacing it could redirect authority.
        return string
    }

    public func writeSourceRoot(_ sourceRoot: String?) throws {
        CFPreferencesSetValue(
            key as CFString,
            sourceRoot as CFString?,
            applicationID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard synchronize() else {
            throw HarvisSourcePreferenceError.synchronizationFailed
        }
    }

    private func synchronize() -> Bool {
        CFPreferencesSynchronize(
            applicationID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
