import Foundation
import XCTest
@testable import HarvisVersionCore

final class HarvisVersionCatalogModelsTests: XCTestCase {
    func testHelperAggregatePreservesFixedEvidencePriority() {
        XCTAssertEqual(
            HarvisStableHelperSummary.aggregate(
                http: .labelMismatch,
                tick: .valid,
                file: .missing,
                receipt: .hashMismatch
            ),
            .launchBindingInvalid
        )
        XCTAssertEqual(
            HarvisStableHelperSummary.aggregate(
                http: .valid,
                tick: .valid,
                file: .notExecutable,
                receipt: .hashMismatch
            ),
            .notExecutable
        )
        XCTAssertEqual(
            HarvisStableHelperSummary.aggregate(
                http: .valid,
                tick: .valid,
                file: .valid,
                receipt: .hashMismatch
            ),
            .hashMismatch
        )
    }

    func testInvalidReceiptAndSourceCannotRetainTrustedPayload() {
        let invalid = HarvisBundleReceiptInspection(status: .invalidContract, receipt: sampleReceipt())
        XCTAssertNil(invalid.receipt)

        let source = HarvisSourceInspection(
            status: .invalid,
            selectedPath: "/selected",
            canonicalRepositoryRoot: "/trusted",
            git: sampleGit()
        )
        XCTAssertNil(source.canonicalRepositoryRoot)
        XCTAssertNil(source.git)
    }

    func testTrustedStatusesRequireTheirClosedPayloadsAtInitialization() {
        let missingReceipt = HarvisBundleReceiptInspection(status: .valid)
        XCTAssertEqual(missingReceipt.status, .invalidContract)
        XCTAssertNil(missingReceipt.receipt)

        let missingGit = HarvisSourceInspection(
            status: .ready,
            selectedPath: "/repo",
            canonicalRepositoryRoot: "/repo"
        )
        XCTAssertEqual(missingGit.status, .invalid)
        XCTAssertNil(missingGit.canonicalRepositoryRoot)
        XCTAssertNil(missingGit.git)

        let missingSelection = HarvisSourceInspection(
            status: .ready,
            selectedPath: nil,
            canonicalRepositoryRoot: "/repo",
            git: sampleGit()
        )
        XCTAssertEqual(missingSelection.status, .invalid)
        XCTAssertNil(missingSelection.selectedPath)
        XCTAssertNil(missingSelection.git)

        let mismatchedRoot = HarvisSourceInspection(
            status: .ready,
            selectedPath: "/repo-a",
            canonicalRepositoryRoot: "/repo-a",
            git: sampleGit(repositoryRoot: "/repo-b")
        )
        XCTAssertEqual(mismatchedRoot.status, .invalid)
        XCTAssertNil(mismatchedRoot.canonicalRepositoryRoot)
        XCTAssertNil(mismatchedRoot.git)

        let contradictoryUnbound = HarvisSourceInspection(
            status: .unbound,
            selectedPath: "/smuggled",
            canonicalRepositoryRoot: "/repo",
            git: sampleGit()
        )
        XCTAssertEqual(contradictoryUnbound.status, .unbound)
        XCTAssertNil(contradictoryUnbound.selectedPath)
        XCTAssertNil(contradictoryUnbound.canonicalRepositoryRoot)
        XCTAssertNil(contradictoryUnbound.git)
    }

    func testContradictoryCodablePayloadsNormalizeFailClosed() throws {
        let decoder = JSONDecoder()
        let missingReceipt = try decoder.decode(
            HarvisBundleReceiptInspection.self,
            from: Data(#"{"status":"valid"}"#.utf8)
        )
        XCTAssertEqual(missingReceipt.status, .invalidContract)
        XCTAssertNil(missingReceipt.receipt)

        let missingGit = try decoder.decode(
            HarvisSourceInspection.self,
            from: Data(
                #"{"status":"ready","selectedPath":"/repo","canonicalRepositoryRoot":"/repo"}"#.utf8
            )
        )
        XCTAssertEqual(missingGit.status, .invalid)
        XCTAssertNil(missingGit.canonicalRepositoryRoot)
        XCTAssertNil(missingGit.git)

        var receiptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(
                HarvisBundleReceiptInspection(status: .valid, receipt: sampleReceipt())
            )) as? [String: Any]
        )
        receiptObject["status"] = HarvisBundleReceiptStatus.invalidContract.rawValue
        let smuggledReceipt = try decoder.decode(
            HarvisBundleReceiptInspection.self,
            from: JSONSerialization.data(withJSONObject: receiptObject)
        )
        XCTAssertEqual(smuggledReceipt.status, .invalidContract)
        XCTAssertNil(smuggledReceipt.receipt)

        var sourceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(
                HarvisSourceInspection(
                    status: .ready,
                    selectedPath: "/repo",
                    canonicalRepositoryRoot: "/repo",
                    git: sampleGit()
                )
            )) as? [String: Any]
        )
        sourceObject["status"] = HarvisSourceStatus.offline.rawValue
        let smuggledSource = try decoder.decode(
            HarvisSourceInspection.self,
            from: JSONSerialization.data(withJSONObject: sourceObject)
        )
        XCTAssertEqual(smuggledSource.status, .offline)
        XCTAssertNil(smuggledSource.canonicalRepositoryRoot)
        XCTAssertNil(smuggledSource.git)

        XCTAssertThrowsError(try decoder.decode(
            HarvisBundleReceiptInspection.self,
            from: Data(#"{"status":"future"}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            HarvisSourceInspection.self,
            from: Data(#"{"status":"future"}"#.utf8)
        ))
    }

    func testClosedDTOsRoundTripThroughCodable() throws {
        let receipt = HarvisBundleReceiptInspection(status: .valid, receipt: sampleReceipt())
        let receiptEncoded = try JSONEncoder().encode(receipt)
        XCTAssertEqual(
            try JSONDecoder().decode(HarvisBundleReceiptInspection.self, from: receiptEncoded),
            receipt
        )

        let value = HarvisSourceInspection(
            status: .ready,
            selectedPath: "/repo/subdirectory",
            canonicalRepositoryRoot: "/repo",
            git: sampleGit()
        )
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(HarvisSourceInspection.self, from: encoded), value)
    }

    func testAlignmentRequiresPositiveProofAndTreatsShallowDoubleNegativeAsUnknown() {
        XCTAssertEqual(
            HarvisVersionAlignmentResolver.resolve(evidence(source: "a", receipt: "a")),
            .exact
        )
        XCTAssertEqual(
            HarvisVersionAlignmentResolver.resolve(
                evidence(source: "b", receipt: "a", object: .negative)
            ),
            .missingCommit
        )
        XCTAssertEqual(
            HarvisVersionAlignmentResolver.resolve(
                evidence(source: "b", receipt: "a", receiptAncestor: .positive)
            ),
            .sourceAhead
        )
        XCTAssertEqual(
            HarvisVersionAlignmentResolver.resolve(
                evidence(source: "b", receipt: "a", sourceAncestor: .positive)
            ),
            .installedAhead
        )
        XCTAssertEqual(
            HarvisVersionAlignmentResolver.resolve(
                evidence(source: "b", receipt: "a", shallow: true)
            ),
            .unknown
        )
        XCTAssertEqual(
            HarvisVersionAlignmentResolver.resolve(
                evidence(source: "b", receipt: "a", shallow: false)
            ),
            .diverged
        )
    }

    private func evidence(
        source: String,
        receipt: String,
        object: HarvisGitProof = .positive,
        receiptAncestor: HarvisGitProof = .negative,
        sourceAncestor: HarvisGitProof = .negative,
        shallow: Bool? = false
    ) -> HarvisAlignmentEvidence {
        HarvisAlignmentEvidence(
            sourceCommit: source,
            receiptCommit: receipt,
            receiptObject: object,
            receiptIsAncestorOfSource: receiptAncestor,
            sourceIsAncestorOfReceipt: sourceAncestor,
            sourceIsShallow: shallow
        )
    }

    private func sampleReceipt() -> HarvisBundleReceiptSummary {
        HarvisBundleReceiptSummary(
            schemaVersion: "harvis.app-bundle-receipt.v1",
            pluginRootMarker: "HarvisPlugin",
            app: HarvisAppIdentity(bundleIdentifier: "local.harzva.harvisbar", executable: "HarvisBar", version: "0.33.0"),
            artifacts: HarvisReceiptArtifacts(runtimeSha256: String(repeating: "a", count: 64), appUnsignedSha256: String(repeating: "b", count: 64), systemExtensionUnsignedSha256: String(repeating: "c", count: 64), records: []),
            provenance: HarvisReceiptProvenance(cacheKey: "fixture", sha256: String(repeating: "d", count: 64), sourceCommit: String(repeating: "e", count: 40), sourceTree: String(repeating: "f", count: 40), stagedPayloadSha256: String(repeating: "0", count: 64)),
            payload: HarvisReceiptPayload(digestAlgorithm: "sha256", digestScope: "fixture", fileCount: 1, sha256: String(repeating: "1", count: 64)),
            appRuntimeAllowlist: HarvisReceiptAllowlist(relativePath: "fixture", sha256: String(repeating: "2", count: 64)),
            systemExtension: HarvisReceiptSystemExtension(bundleIdentifier: "extension", bundleName: "extension", executable: "extension", version: "0.33.0")
        )
    }

    private func sampleGit(repositoryRoot: String = "/repo") -> HarvisSourceGitSummary {
        HarvisSourceGitSummary(
            repositoryRoot: repositoryRoot,
            headState: .attached,
            branch: "main",
            headCommit: String(repeating: "a", count: 40),
            changedFileCount: 0,
            upstream: nil,
            aheadCount: nil,
            behindCount: nil,
            isShallow: false,
            trackingSnapshotIncomplete: false,
            observedAt: Date(timeIntervalSince1970: 0),
            remotes: [],
            worktrees: []
        )
    }
}
