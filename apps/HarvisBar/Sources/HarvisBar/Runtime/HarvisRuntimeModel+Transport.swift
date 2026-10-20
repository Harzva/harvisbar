import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

extension HarvisRuntimeModel {
    func fetch<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw HarvisBarError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        if let token = readAuthToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw mapNetworkError(error, path: path)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            throw HarvisBarError.unauthorized(path)
        }
        guard (200..<300).contains(status) else {
            let message = try? JSONDecoder()
                .decode(APIErrorEnvelope.self, from: data)
                .error?
                .message
            throw HarvisBarError.httpStatus(status, message ?? nil)
        }
        let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
        guard envelope.ok, let data = envelope.data else {
            throw HarvisBarError.api(envelope.error?.message ?? "API request failed")
        }
        return data
    }

    func post<T: Decodable>(
        _ path: String,
        body: [String: Any],
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        guard let url = components.url else {
            throw HarvisBarError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        if let token = readAuthToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw mapNetworkError(error, path: path)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            throw HarvisBarError.unauthorized(path)
        }
        guard (200..<300).contains(status) else {
            let message = try? JSONDecoder()
                .decode(APIErrorEnvelope.self, from: data)
                .error?
                .message
            throw HarvisBarError.httpStatus(status, message ?? nil)
        }
        let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
        guard envelope.ok, let data = envelope.data else {
            throw HarvisBarError.api(envelope.error?.message ?? "API request failed")
        }
        return data
    }

    func readAuthToken() -> String? {
        guard let value = try? String(contentsOfFile: tokenFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    func mapNetworkError(_ error: Error, path: String) -> Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return HarvisBarError.timeout(path)
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return HarvisBarError.offline(path)
            default:
                return HarvisBarError.network(path, urlError.localizedDescription)
            }
        }
        return error
    }

    func runProcess(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = BoundedProcessRunner.defaultTimeout,
        standardOutputLimit: Int = 1_048_576
    ) async throws -> String {
        let result = try await BoundedProcessRunner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit
        )
        guard result.terminationStatus == 0 else {
            let details = result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            let message = details.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HarvisBarError.process(
                message.isEmpty
                    ? "Process exited with status \(result.terminationStatus): \(executable)"
                    : message
            )
        }
        return result.standardOutput
    }

    func expanded(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }

    func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/Users/", with: "[local]/")
            .replacingOccurrences(of: "/Volumes/", with: "[volume]/")
    }
}
