import Foundation

struct ManagedProjectFileStatisticsHelperInvocation: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

/// A private process boundary for filesystem enumeration. The mode is handled
/// before HarvisRuntimeModel or any windows start, and is intentionally not
/// exposed through the public HarvisRuntime CLI.
enum ManagedProjectFileStatisticsHelper {
    static let argument = "--harvis-internal-project-file-statistics"

    static func invokeIfRequested(
        arguments: [String],
        inspect: (String) throws -> ManagedProjectFileStatistics = {
            try ManagedProjectFileInspector.inspect(path: $0)
        }
    ) -> ManagedProjectFileStatisticsHelperInvocation? {
        guard arguments.contains(argument) else { return nil }

        guard arguments.count == 3,
              arguments[1] == argument else {
            return failure(
                exitCode: 64,
                message: "Invalid internal project statistics arguments."
            )
        }

        do {
            let statistics = try inspect(arguments[2])
            var output = try JSONEncoder().encode(statistics)
            output.append(0x0A)
            return ManagedProjectFileStatisticsHelperInvocation(
                exitCode: 0,
                standardOutput: output,
                standardError: Data()
            )
        } catch {
            return failure(exitCode: 1, message: error.localizedDescription)
        }
    }

    static func decodeStatistics(
        from data: Data
    ) throws -> ManagedProjectFileStatistics {
        do {
            return try JSONDecoder().decode(
                ManagedProjectFileStatistics.self,
                from: data
            )
        } catch {
            throw ManagedProjectFileStatisticsError.invalidHelperResponse(
                error.localizedDescription
            )
        }
    }

    private static func failure(
        exitCode: Int32,
        message: String
    ) -> ManagedProjectFileStatisticsHelperInvocation {
        ManagedProjectFileStatisticsHelperInvocation(
            exitCode: exitCode,
            standardOutput: Data(),
            standardError: Data((message + "\n").utf8)
        )
    }
}
