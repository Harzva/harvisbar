import CryptoKit
import Foundation

/// Attests the exact, user-owned conversation-management preset before DSH is
/// allowed to receive even the irreversible fact projection. The expected
/// composition contains one persona row and no model-facing tool rows.
struct DshHostManagedConversationInsightCapabilityVerifier:
    ManagedConversationInsightCapabilityVerifying {
    static let expectedCompositionSHA256 =
        "dce98530c709953aed6c3ef7be2f8173ffd34a57c1699c38f16aaccf926e2d2e"

    private let makeClient: @Sendable (DshRuntimeEndpoint) -> DshHostApiClient
    private let acceptedCompositionSHA256: String
    private let attestReviewedRuntime: @Sendable () throws -> String

    init(
        makeClient: @escaping @Sendable (DshRuntimeEndpoint) -> DshHostApiClient = {
            DshHostApiClient(endpoint: $0)
        },
        acceptedCompositionSHA256: String = Self.expectedCompositionSHA256,
        attestReviewedRuntime: @escaping @Sendable () throws -> String = {
            try Self.reviewedRuntimeRevision()
        }
    ) {
        self.makeClient = makeClient
        self.acceptedCompositionSHA256 = acceptedCompositionSHA256
        self.attestReviewedRuntime = attestReviewedRuntime
    }

    func verify(
        endpoint: DshRuntimeEndpoint,
        presetID: String
    ) async -> ManagedConversationInsightSecurityAvailability {
        guard DshMetaAgentPolicy.isDedicatedEndpoint(endpoint),
              presetID == DshMetaAgentPolicy.requiredPresetID else {
            return .unavailable("The endpoint or preset is not the dedicated Harvis brain.")
        }

        do {
            let client = makeClient(endpoint)
            let roster = try await client.agentPresetList()
            let matching = roster.presets.filter { $0.id == presetID }
            guard matching.count == 1,
                  matching[0].trust == .user,
                  matching[0].broken == nil else {
                return .unavailable("The exact user-owned Harvis preset is missing or broken.")
            }

            let composition = try await client.agentPresetRead(
                DshAgentPresetReadPayload(agentPreset: presetID)
            )
            guard composition.agentPreset == presetID,
                  composition.trust == .user else {
                return .unavailable("The preset composition identity did not match the roster.")
            }
            let digest = SHA256.hash(data: Data(composition.content.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == acceptedCompositionSHA256 else {
                return .unavailable(
                    "The Harvis preset composition changed; its zero-tool policy must be reviewed again."
                )
            }
            let runtimeRevision = try attestReviewedRuntime()
            let combinedRevision = Self.combinedRevision(
                compositionSHA256: digest,
                runtimeRevision: runtimeRevision
            )

            return .verified(
                ManagedConversationInsightCapabilityAttestation(
                    endpoint: endpoint,
                    presetID: presetID,
                    catalogRevision: combinedRevision,
                    toolIdentifiers: [],
                    allowsCommandExecution: false,
                    allowsFileMutation: false,
                    allowsNetwork: false,
                    allowsMCP: false
                )
            )
        } catch {
            return .unavailable(
                "The DSH Host could not attest the exact zero-tool preset composition."
            )
        }
    }

    /// The Host API currently exposes the preset composition but not a
    /// resolved model-facing capability manifest. Pin the reviewed dedicated
    /// profile and the only mounted row implementation as a second,
    /// fail-closed attestation layer. Any DSH/profile/package update disables
    /// insight analysis until these hashes are reviewed and updated.
    static func reviewedRuntimeRevision() throws -> String {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh-harvis-meta", isDirectory: true)
        let reviewedFiles: [(String, String)] = [
            ("profiles/web/cordis.yml", "c300dcf2ebc5f02062d6591268d29d3db6fe45e0cb138f5467276fe2ba06076e"),
            ("profiles/web/cordis.patch.yml", "ef189a8c27db6d63930aa3046a3040482e952eafcb7487c644d508e8d461f027"),
            ("profiles/web/package.json", "210068ddb9ebc4cdf395ebb53020be6ccaaedb917e74dae16296d62394626398"),
            ("profiles/web/pnpm-workspace.yaml", "ae7c5b68e2f157528e62885804e69e88583897b775e03c86fcbe52feaf498aba"),
            ("profiles/node_modules/@deepseek-ai/dsh-persona/package.json", "a84fbb0919c92b6a3e04b099cf4dc82587445c901eeab6845ad078e417176bf6"),
            ("profiles/node_modules/@deepseek-ai/dsh-persona/lib/index.js", "37a223d0c44fac7fd9d69f55b972828b177db7092fc45302c8b1938e595b9ace"),
            ("profiles/node_modules/@deepseek-ai/dsh-persona/lib/invariant.js", "aa92b1dbadfb892f629f86c7d95c3bb03d7ba4ad1af7b9434b6ea01360d03edf"),
        ]
        var aggregate = Data()
        for (relativePath, expectedHash) in reviewedFiles {
            let url = root.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0, size <= 1_000_000 else {
                throw RuntimeAttestationError.invalidReviewedFile(relativePath)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualHash == expectedHash else {
                throw RuntimeAttestationError.reviewedFileChanged(relativePath)
            }
            aggregate.append(Data(relativePath.utf8))
            aggregate.append(0)
            aggregate.append(Data(actualHash.utf8))
            aggregate.append(0)
        }
        let reviewedTrees: [(String, String)] = [
            ("profiles/node_modules/@deepseek-ai/dsh-base", "c904e2c21c288b03f372bbd12c84fe7dbc1455ac6553f5c857fcfe905e31fd03"),
            ("profiles/node_modules/@deepseek-ai/dsh-web-app", "21e2557c16e384dd8ae7ad289c54761273e88b28831f4b860ed9700570078a67"),
            ("profiles/node_modules/@deepseek-ai/dsh-agent-presets", "4099e45305e07f6d107bfc3e6e1311ed621729b9d8f0169456aff1f2fff7f882"),
        ]
        for (relativeRoot, expectedHash) in reviewedTrees {
            let actualHash = try reviewedTreeSHA256(
                root: root.appendingPathComponent(relativeRoot)
            )
            guard actualHash == expectedHash else {
                throw RuntimeAttestationError.reviewedFileChanged(relativeRoot)
            }
            aggregate.append(Data(relativeRoot.utf8))
            aggregate.append(0)
            aggregate.append(Data(actualHash.utf8))
            aggregate.append(0)
        }
        let digest = SHA256.hash(data: aggregate)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    /// Hashes every executable JS file plus the package/profile composition
    /// documents in a reviewed DSH bundle. This binds the web patch that
    /// disables the host agent-plane tools, the preset realm resolver, and the
    /// referenced bundle implementations—not merely their package names.
    private static func reviewedTreeSHA256(root unresolvedRoot: URL) throws
        -> String {
        let root = unresolvedRoot.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
           let enumerator = FileManager.default.enumerator(
               at: root,
               includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
               options: [.skipsHiddenFiles]
           ) else {
            throw RuntimeAttestationError.invalidReviewedFile(root.lastPathComponent)
        }
        var files: [(String, URL, Int)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard name == "package.json"
                    || name == "cordis.patch.yml"
                    || url.pathExtension == "js" else { continue }
            guard let size = values.fileSize,
                  size >= 0, size <= 2_000_000 else {
                throw RuntimeAttestationError.invalidReviewedFile(name)
            }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path.hasPrefix(prefix) else {
                throw RuntimeAttestationError.invalidReviewedFile(name)
            }
            files.append((String(url.path.dropFirst(prefix.count)), url, size))
        }
        guard !files.isEmpty,
              files.reduce(0, { $0 + $1.2 }) <= 5_000_000 else {
            throw RuntimeAttestationError.invalidReviewedFile(root.lastPathComponent)
        }
        var aggregate = Data()
        for (relativePath, url, _) in files.sorted(by: { $0.0 < $1.0 }) {
            let pathData = Data(relativePath.utf8)
            let contents = try Data(contentsOf: url, options: .mappedIfSafe)
            appendFramed(pathData, to: &aggregate)
            appendFramed(contents, to: &aggregate)
        }
        return SHA256.hash(data: aggregate)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func appendFramed(_ value: Data, to aggregate: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { aggregate.append(contentsOf: $0) }
        aggregate.append(value)
    }

    private static func combinedRevision(
        compositionSHA256: String,
        runtimeRevision: String
    ) -> String {
        let material = "composition:\(compositionSHA256)\nruntime:\(runtimeRevision)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    private enum RuntimeAttestationError: Error {
        case invalidReviewedFile(String)
        case reviewedFileChanged(String)
    }
}
