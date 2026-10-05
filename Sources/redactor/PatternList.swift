import Foundation

enum RedactorPaths {
    static var supportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Redactor", isDirectory: true)
    }

    static var patternFile: URL {
        supportDirectory.appendingPathComponent("patterns.json")
    }

    static var socketFile: URL {
        supportDirectory.appendingPathComponent("status.sock")
    }

    static var lockFile: URL {
        supportDirectory.appendingPathComponent("agent.lock")
    }

    static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/Redactor", isDirectory: true)
    }

    static var agentLog: URL {
        logDirectory.appendingPathComponent("agent.log")
    }

    static var launchAgentPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents/com.redactor.agent.plist")
    }

    static func ensure(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

struct PatternFileError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct TokenRule {
    var name: String
    var regex: NSRegularExpression
    var valueGroup: Int
}

struct PatternList {
    var replacement: String
    var minimumValueLength: Int
    var ignoreValues: Set<String>
    var parameterNames: [String]
    var normalizedNames: Set<String>
    var tokenPatterns: [TokenRule]
    var sourceURL: URL

    static func load(strict: Bool) throws -> (list: PatternList, error: String?) {
        let support = RedactorPaths.patternFile
        if FileManager.default.fileExists(atPath: support.path) {
            do {
                return (try parse(url: support), nil)
            } catch {
                if strict { throw error }
                guard let factory = locateFactory() else { throw error }
                let list = try parse(url: factory)
                return (list, menuMessage(for: error))
            }
        }
        guard let factory = locateFactory() else {
            throw PatternFileError(message: "pattern file is missing")
        }
        return (try parse(url: factory), nil)
    }

    static func locateFactory() -> URL? {
        if let bundled = Bundle.main.url(forResource: "patterns", withExtension: "json") {
            return bundled
        }
        let raw = CommandLine.arguments.first ?? ""
        var directory: URL
        if raw.contains("/") {
            directory = URL(fileURLWithPath: raw).resolvingSymlinksInPath().deletingLastPathComponent()
        } else {
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("patterns.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    static func parse(url: URL) throws -> PatternList {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PatternFileError(message: "pattern file is invalid")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PatternFileError(message: "pattern file is invalid")
        }
        let names = try stringArray(root["parameterNames"], absent: []) ?? []
        let ignores = try stringArray(root["ignoreValues"], absent: nil)
        let minimum = try minimumLength(root["minimumValueLength"])
        let rules = try tokenRules(root["tokenPatterns"])
        let replacement = try replacementString(root["replacement"], rules: rules)
        let normalized = Set(names.map { KeyNormalization.normalize($0) })
        let ignoreSet = Set((ignores ?? defaultIgnoreValues).map { $0.lowercased() })
        return PatternList(
            replacement: replacement,
            minimumValueLength: minimum,
            ignoreValues: ignoreSet,
            parameterNames: names,
            normalizedNames: normalized,
            tokenPatterns: rules,
            sourceURL: url
        )
    }

    private static func menuMessage(for error: Error) -> String {
        let text = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        if text.count <= 240 { return text }
        return String(text.prefix(240))
    }

    private static func stringArray(_ value: Any?, absent: [String]?) throws -> [String]? {
        if value == nil { return absent }
        guard let array = value as? [Any] else {
            throw PatternFileError(message: "pattern file is invalid")
        }
        var names: [String] = []
        for item in array {
            guard let name = item as? String, !name.isEmpty else {
                throw PatternFileError(message: "pattern file is invalid")
            }
            names.append(name)
        }
        return names
    }

    private static func minimumLength(_ value: Any?) throws -> Int {
        if value == nil { return 4 }
        let number: Int
        if let int = value as? Int {
            number = int
        } else if let numberValue = value as? NSNumber {
            number = numberValue.intValue
        } else {
            throw PatternFileError(message: "pattern file is invalid")
        }
        if number < 0 { throw PatternFileError(message: "pattern file is invalid") }
        return number
    }

    private static func tokenRules(_ value: Any?) throws -> [TokenRule] {
        if value == nil { return [] }
        guard let array = value as? [Any] else {
            throw PatternFileError(message: "pattern file is invalid")
        }
        var rules: [TokenRule] = []
        for item in array {
            guard let object = item as? [String: Any] else { continue }
            guard let name = object["name"] as? String, !name.isEmpty else { continue }
            guard let pattern = object["regex"] as? String else { continue }
            if pattern.count > 500 || pattern.contains("(.+)+") || pattern.contains("(.*)+") || pattern.contains(".*.*") {
                continue
            }
            let group: Int
            if object["valueGroup"] == nil {
                group = 0
            } else if let int = object["valueGroup"] as? Int {
                group = int
            } else if let number = object["valueGroup"] as? NSNumber {
                group = number.intValue
            } else {
                continue
            }
            if group < 0 { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            rules.append(TokenRule(name: name, regex: regex, valueGroup: group))
        }
        return rules
    }

    private static func replacementString(_ value: Any?, rules: [TokenRule]) throws -> String {
        if value == nil { return "[redacted]" }
        guard let text = value as? String else {
            throw PatternFileError(message: "pattern file is invalid")
        }
        if text.isEmpty { return "" }
        if text.count > 80 || text.contains("\n") || text.contains("\r") { return "[redacted]" }
        if rules.contains(where: { ruleMatches($0, text) }) { return "[redacted]" }
        return text
    }

    private static func ruleMatches(_ rule: TokenRule, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return rule.regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

enum KeyNormalization {
    static func normalize(_ raw: String) -> String {
        var out = ""
        let chars = Array(raw)
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if character == "-" || character == "." || character == " " {
                out.append("_")
                index += 1
                continue
            }
            if character.isUppercase {
                var end = index + 1
                while end < chars.count && chars[end].isUppercase { end += 1 }
                let nextIsLower = end < chars.count && chars[end].isLowercase
                let previous = out.last
                let breakBefore = previous?.isLowercase == true || previous?.isNumber == true
                if nextIsLower && (end - index) > 1 {
                    if breakBefore { out.append("_") }
                    for cursor in index..<(end - 1) { out.append(chars[cursor]) }
                    out.append("_")
                    out.append(chars[end - 1])
                    index = end
                    continue
                }
                if breakBefore { out.append("_") }
                out.append(character)
                index += 1
                continue
            }
            out.append(character)
            index += 1
        }
        return out.lowercased()
    }

    static func matchName(_ raw: String, names: [String], normalized: Set<String>) -> String? {
        let form = normalize(raw)
        if normalized.contains(form) { return form }
        let parts = form.split(separator: "_").map(String.init)
        if parts.count >= 2 {
            for length in stride(from: parts.count - 1, through: 1, by: -1) {
                let tail = parts.suffix(length).joined(separator: "_")
                if normalized.contains(tail) { return tail }
            }
        }
        let stripped = form.replacingOccurrences(of: "_", with: "")
        guard !stripped.isEmpty else { return nil }
        var best: String?
        for name in names {
            let norm = normalize(name)
            let folded = norm.replacingOccurrences(of: "_", with: "")
            if folded == stripped && (best == nil || norm.count > best!.count) {
                best = norm
            }
        }
        return best
    }
}

private let defaultIgnoreValues = [
    "changeme", "change_me", "placeholder", "your_api_key", "your-api-key", "your_token",
    "your_password", "xxx", "xxxx", "xxxxx", "redacted", "[redacted]", "none", "null", "nil",
    "true", "false", "undefined", "todo", "test", "testing", "example", "sample", "secret",
    "password", "token", "apikey", "api_key", "insert_key_here", "replace_me", "enabled",
    "disabled", "yes", "no", "on", "off", "required", "optional", "localhost", "bearer", "basic",
]
