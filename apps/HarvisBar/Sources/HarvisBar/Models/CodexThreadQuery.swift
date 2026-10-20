import Foundation

struct CodexThreadQuery {
    var terms: [String] = []
    var excludedTerms: [String] = []
    var tags: [String] = []
    var projects: [String] = []
    var models: [String] = []
    var statuses: [String] = []
    var pinned: Bool?
    var subagent: Bool?
    var sidechat: Bool?
    var main: Bool?

    init(_ raw: String) {
        for token in Self.tokens(raw) {
            let excluded = token.hasPrefix("-")
            let value = excluded ? String(token.dropFirst()) : token
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                if !value.isEmpty {
                    if excluded {
                        excludedTerms.append(value)
                    } else {
                        terms.append(value)
                    }
                }
                continue
            }
            let field = parts[0].lowercased()
            let operand = parts[1]
            guard !operand.isEmpty else { continue }
            switch field {
            case "tag": tags.append(operand)
            case "project", "dir": projects.append(operand)
            case "model": models.append(operand)
            case "status": statuses.append(operand.lowercased())
            case "is" where operand.caseInsensitiveCompare("pinned") == .orderedSame:
                pinned = !excluded
            case "is" where operand.caseInsensitiveCompare("unpinned") == .orderedSame:
                pinned = excluded
            case "is" where ["subagent", "agent"].contains(operand.lowercased()):
                subagent = !excluded
            case "is" where operand.caseInsensitiveCompare("sidechat") == .orderedSame:
                sidechat = !excluded
            case "is" where operand.caseInsensitiveCompare("main") == .orderedSame:
                main = !excluded
            default:
                if excluded {
                    excludedTerms.append(value)
                } else {
                    terms.append(value)
                }
            }
        }
    }

    func matches(
        _ thread: CodexThreadSummary,
        tags threadTags: [String],
        isPinned: Bool
    ) -> Bool {
        if let pinned, pinned != isPinned { return false }
        if let subagent, subagent != thread.isSubagent { return false }
        if let sidechat, sidechat != thread.isSidechat { return false }
        if let main, main != (!thread.isSubagent && !thread.isSidechat) { return false }
        if !tags.allSatisfy({ query in
            threadTags.contains { $0.localizedCaseInsensitiveContains(query) }
        }) {
            return false
        }
        if !projects.allSatisfy({ thread.cwd.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        if !models.allSatisfy({
            thread.model?.localizedCaseInsensitiveContains($0) == true
        }) {
            return false
        }
        if !statuses.allSatisfy({ query in
            thread.trustProjection.state.rawValue.localizedCaseInsensitiveContains(query)
        }) {
            return false
        }
        let haystack = [
            thread.title,
            thread.cwd,
            thread.model ?? "",
            thread.agentNickname ?? "",
            thread.agentRole ?? "",
            thread.agentPath ?? "",
            threadTags.joined(separator: " ")
        ].joined(separator: " ")
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
            && excludedTerms.allSatisfy { !haystack.localizedCaseInsensitiveContains($0) }
    }

    func matches(
        _ thread: ManagedChatThread,
        tags threadTags: [String],
        isPinned: Bool
    ) -> Bool {
        if let pinned, pinned != isPinned { return false }
        if let subagent, subagent != thread.isSubagent { return false }
        if let sidechat, sidechat != thread.isSidechat { return false }
        if let main, main != (!thread.isSubagent && !thread.isSidechat) { return false }
        if !tags.allSatisfy({ query in
            threadTags.contains { $0.localizedCaseInsensitiveContains(query) }
        }) {
            return false
        }
        if !projects.allSatisfy({ thread.cwd.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        if !models.allSatisfy({
            thread.model?.localizedCaseInsensitiveContains($0) == true
        }) {
            return false
        }
        if !statuses.allSatisfy({ query in
            thread.trustProjection.state.rawValue.localizedCaseInsensitiveContains(query)
        }) {
            return false
        }
        let haystack = [
            thread.title,
            thread.cwd,
            thread.model ?? "",
            thread.agentNickname ?? "",
            thread.agentRole ?? "",
            thread.agentPath ?? "",
            thread.provider.label,
            threadTags.joined(separator: " ")
        ].joined(separator: " ")
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
            && excludedTerms.allSatisfy { !haystack.localizedCaseInsensitiveContains($0) }
    }

    private static func tokens(_ raw: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        for character in raw {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty {
                    values.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { values.append(current) }
        return values
    }
}
