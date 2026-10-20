import Foundation

actor CodexAppServerPool {
    private let executableURL: URL?
    private let executableArgumentsPrefix: [String]
    private let requestTimeout: TimeInterval
    private var connections: [String: CodexAppServerConnection] = [:]

    init(
        executableURL: URL? = nil,
        executableArgumentsPrefix: [String] = [],
        requestTimeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        self.executableArgumentsPrefix = executableArgumentsPrefix
        self.requestTimeout = requestTimeout
    }

    func connection(for homePath: String) -> CodexAppServerConnection {
        let normalized = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL
            .path
        if let existing = connections[normalized] {
            return existing
        }
        let connection = CodexAppServerConnection(
            homePath: normalized,
            executableURL: executableURL,
            executableArgumentsPrefix: executableArgumentsPrefix,
            requestTimeout: requestTimeout
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
