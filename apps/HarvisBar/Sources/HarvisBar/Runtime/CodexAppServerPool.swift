import Foundation

actor CodexAppServerPool {
    private let executableURL: URL?
    private let executableArgumentsPrefix: [String]
    private let requestTimeout: TimeInterval
    private let environmentPolicy: CodexProfileEnvironmentPolicy
    private var connections: [String: CodexAppServerConnection] = [:]

    init(
        executableURL: URL? = nil,
        executableArgumentsPrefix: [String] = [],
        requestTimeout: TimeInterval = 30,
        environmentPolicy: CodexProfileEnvironmentPolicy = .inherited
    ) {
        self.executableURL = executableURL
        self.executableArgumentsPrefix = executableArgumentsPrefix
        self.requestTimeout = requestTimeout
        self.environmentPolicy = environmentPolicy
    }

    func connection(for homePath: String) -> CodexAppServerConnection {
        let normalized = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
            .path
        if let existing = connections[normalized] {
            return existing
        }
        let connection = CodexAppServerConnection(
            homePath: normalized,
            executableURL: executableURL,
            executableArgumentsPrefix: executableArgumentsPrefix,
            requestTimeout: requestTimeout,
            environmentPolicy: environmentPolicy
        )
        connections[normalized] = connection
        return connection
    }

    func stopAll() async {
        let values = Array(connections.values)
        connections.removeAll()
        for connection in values {
            await connection.stop()
        }
    }

    func connectionCount() -> Int {
        connections.count
    }
}
