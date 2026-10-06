import Foundation

struct Redaction {
    var text: String
    var names: [String]
}

struct SecretRedactor {
    var list: PatternList

    func redact(_ text: String) -> Redaction {
        let spans = merge(assignmentSpans(in: text) + tokenSpans(in: text))
        var names: [String] = []
        var seen = Set<String>()
        for span in spans {
            for name in span.names where seen.insert(name).inserted {
                names.append(name)
            }
        }
        var output = text
        for span in spans.reversed() {
            output.replaceSubrange(span.range, with: list.replacement)
        }
        return Redaction(text: output, names: names)
    }

    private struct Span {
        var range: Range<String.Index>
        var names: [String]
    }

    private struct RawAssignment {
        var name: String?
        var value: Range<String.Index>?
        var resume: String.Index
    }

    private func assignmentSpans(in text: String) -> [Span] {
        var spans: [Span] = []
        var hits = 0
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            var lineEnd = lineStart
            while lineEnd < text.endIndex && text[lineEnd] != "\n" && text[lineEnd] != "\r" {
                lineEnd = text.index(after: lineEnd)
            }
            scanLine(text, lineStart: lineStart, lineEnd: lineEnd, spans: &spans, hits: &hits)
            if lineEnd >= text.endIndex { break }
            var next = text.index(after: lineEnd)
            if text[lineEnd] == "\r" && next < text.endIndex && text[next] == "\n" {
                next = text.index(after: next)
            }
            lineStart = next
        }
        return spans
    }

    private func scanLine(
        _ text: String,
        lineStart: String.Index,
        lineEnd: String.Index,
        spans: inout [Span],
        hits: inout Int
    ) {
        var index = lineStart
        while index < lineEnd {
            if let found = matchAt(text, index, lineStart: lineStart, lineEnd: lineEnd), found.resume > index {
                if let name = found.name, let range = found.value, !range.isEmpty, hits < 200 {
                    spans.append(Span(range: range, names: [name]))
                    hits += 1
                }
                index = found.resume
                continue
            }
            index = text.index(after: index)
        }
    }

    private func matchAt(
        _ text: String,
        _ index: String.Index,
        lineStart: String.Index,
        lineEnd: String.Index
    ) -> RawAssignment? {
        if text[index] == "\"" || text[index] == "'" {
            return matchQuotedKey(text, index, lineStart: lineStart, lineEnd: lineEnd)
        }
        if let previous = previousCharacter(text, index), isKeyCharacter(previous) { return nil }
        guard isKeyStart(text[index]) else { return nil }
        return matchPlainKey(text, index, lineStart: lineStart, lineEnd: lineEnd)
    }

    private func matchPlainKey(
        _ text: String,
        _ index: String.Index,
        lineStart: String.Index,
        lineEnd: String.Index
    ) -> RawAssignment? {
        var end = index
        while end < lineEnd && isKeyCharacter(text[end]) {
            end = text.index(after: end)
        }
        return finish(
            text,
            key: String(text[index..<end]),
            keyStart: index,
            afterKey: end,
            quotedKey: false,
            lineStart: lineStart,
            lineEnd: lineEnd
        )
    }

    private func matchQuotedKey(
        _ text: String,
        _ index: String.Index,
        lineStart: String.Index,
        lineEnd: String.Index
    ) -> RawAssignment? {
        let quote = text[index]
        var cursor = text.index(after: index)
        var key = ""
        var closed = false
        while cursor < lineEnd {
            let character = text[cursor]
            if character == "\\" {
                let escaped = text.index(after: cursor)
                if escaped < lineEnd {
                    key.append(text[escaped])
                    cursor = text.index(after: escaped)
                    continue
                }
            }
            if character == quote {
                closed = true
                break
            }
            key.append(character)
            cursor = text.index(after: cursor)
        }
        guard closed else { return nil }
        let after = text.index(after: cursor)
        return finish(
            text,
            key: key,
            keyStart: index,
            afterKey: after,
            quotedKey: true,
            lineStart: lineStart,
            lineEnd: lineEnd
        )
    }

    private func finish(
        _ text: String,
        key: String,
        keyStart: String.Index,
        afterKey: String.Index,
        quotedKey: Bool,
        lineStart: String.Index,
        lineEnd: String.Index
    ) -> RawAssignment? {
        let separatorIndex = skipHorizontalSpace(text, afterKey, lineEnd)
        guard separatorIndex < lineEnd else { return nil }
        let separator = text[separatorIndex]
        guard separator == "=" || separator == ":" else { return nil }
        if separator == ":" && !quotedKey && !colonPrefixAllowed(text, lineStart: lineStart, keyStart: keyStart) {
            return nil
        }
        var valueOrigin = text.index(after: separatorIndex)
        if separator == "=" {
            let rocket = skipHorizontalSpace(text, valueOrigin, lineEnd)
            if rocket < lineEnd && text[rocket] == ">" {
                valueOrigin = text.index(after: rocket)
            }
        }
        let trimmed = skipHorizontalSpace(text, valueOrigin, lineEnd)
        if trimmed != valueOrigin && looksLikeKeyEquals(text, trimmed, lineEnd) {
            return RawAssignment(name: nil, value: nil, resume: valueOrigin)
        }
        let (valueRange, resume) = readValue(text, trimmed, lineEnd)
        let matched = KeyNormalization.matchName(key, names: list.parameterNames, normalized: list.normalizedNames)
        if let matched, !valueRange.isEmpty, !assignmentIgnored(String(text[valueRange])) {
            return RawAssignment(name: matched, value: valueRange, resume: resume)
        }
        let advanced = trimmed > keyStart ? trimmed : text.index(after: keyStart)
        return RawAssignment(name: nil, value: nil, resume: advanced)
    }

    private func readValue(
        _ text: String,
        _ start: String.Index,
        _ lineEnd: String.Index
    ) -> (Range<String.Index>, String.Index) {
        if start < lineEnd && (text[start] == "\"" || text[start] == "'") {
            return readQuotedValue(text, start, lineEnd)
        }
        return readPlainValue(text, start, lineEnd)
    }

    private func readQuotedValue(
        _ text: String,
        _ open: String.Index,
        _ lineEnd: String.Index
    ) -> (Range<String.Index>, String.Index) {
        let quote = text[open]
        var cursor = text.index(after: open)
        let inner = cursor
        while cursor < lineEnd {
            if text[cursor] == "\\" {
                let escaped = text.index(after: cursor)
                if escaped < lineEnd {
                    cursor = text.index(after: escaped)
                    continue
                }
            }
            if text[cursor] == quote {
                return (inner..<cursor, text.index(after: cursor))
            }
            cursor = text.index(after: cursor)
        }
        return (open..<open, open)
    }

    private func readPlainValue(
        _ text: String,
        _ start: String.Index,
        _ lineEnd: String.Index
    ) -> (Range<String.Index>, String.Index) {
        var cursor = start
        while cursor < lineEnd {
            let character = text[cursor]
            if character == ";" || character == "\"" || character == "'" || character == "\u{201C}" || character == "\u{201D}" || character == "\u{2018}" || character == "\u{2019}" {
                return (start..<cursor, cursor)
            }
            if character == "&" {
                let after = text.index(after: cursor)
                if looksLikeKeyEquals(text, after, lineEnd) {
                    return (start..<cursor, cursor)
                }
            }
            if character == " " || character == "\t" {
                let content = skipHorizontalSpace(text, text.index(after: cursor), lineEnd)
                if looksLikeKeyEquals(text, content, lineEnd) {
                    return (start..<cursor, cursor)
                }
            }
            cursor = text.index(after: cursor)
        }
        return (start..<lineEnd, lineEnd)
    }

    private func looksLikeKeyEquals(_ text: String, _ start: String.Index, _ lineEnd: String.Index) -> Bool {
        var cursor = start
        guard cursor < lineEnd else { return false }
        var quote: Character?
        if text[cursor] == "\"" || text[cursor] == "'" {
            quote = text[cursor]
            cursor = text.index(after: cursor)
        }
        guard cursor < lineEnd, isKeyStart(text[cursor]) else { return false }
        cursor = text.index(after: cursor)
        while cursor < lineEnd && isKeyCharacter(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        if let quote {
            guard cursor < lineEnd, text[cursor] == quote else { return false }
            cursor = text.index(after: cursor)
        }
        cursor = skipHorizontalSpace(text, cursor, lineEnd)
        return cursor < lineEnd && text[cursor] == "="
    }

    private func colonPrefixAllowed(_ text: String, lineStart: String.Index, keyStart: String.Index) -> Bool {
        let prefix = String(text[lineStart..<keyStart]).trimmingCharacters(in: .whitespaces)
        if prefix.isEmpty { return true }
        return ["-", "*", "+", "•", "●", "·", "export", "set", "env"].contains(prefix)
    }

    private func assignmentIgnored(_ value: String) -> Bool {
        if value.count < list.minimumValueLength { return true }
        if list.ignoreValues.contains(value.lowercased()) { return true }
        if value == list.replacement { return true }
        if isPlaceholder(value) { return true }
        let lowered = value.lowercased()
        if lowered.hasPrefix("process.env") || lowered.hasPrefix("os.environ") || lowered.hasPrefix("getenv(") || lowered.hasPrefix("env(") {
            return true
        }
        if value.count >= 4 && value.allSatisfy({ "*xX#-".contains($0) }) { return true }
        return false
    }

    private func isPlaceholder(_ value: String) -> Bool {
        let patterns = [
            #"^\$[A-Za-z_][A-Za-z0-9_]*$"#,
            #"^\$\{[^}]+\}$"#,
            #"^\$\([^)]+\)$"#,
            #"^%[A-Za-z0-9_]+%$"#,
            #"^<[^>\r\n]+>$"#,
            #"^\{\{[^}]+\}\}$"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    private func tokenSpans(in text: String) -> [Span] {
        guard !text.isEmpty else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        var spans: [Span] = []
        for rule in list.tokenPatterns {
            var found = 0
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, stop in
                guard let match else { return }
                found += 1
                if found > 200 {
                    stop.pointee = true
                    return
                }
                guard rule.valueGroup < match.numberOfRanges else { return }
                let nsRange = match.range(at: rule.valueGroup)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return }
                let count = text.distance(from: range.lowerBound, to: range.upperBound)
                if count < 4 || count > 100_000 { return }
                spans.append(Span(range: range, names: [rule.name]))
            }
        }
        return spans
    }

    private func merge(_ spans: [Span]) -> [Span] {
        let sorted = spans.sorted { left, right in
            if left.range.lowerBound == right.range.lowerBound {
                return left.range.upperBound < right.range.upperBound
            }
            return left.range.lowerBound < right.range.lowerBound
        }
        var merged: [Span] = []
        for span in sorted {
            if span.range.isEmpty { continue }
            if var last = merged.last, span.range.lowerBound <= last.range.upperBound {
                let upper = max(last.range.upperBound, span.range.upperBound)
                last.range = last.range.lowerBound..<upper
                for name in span.names where !last.names.contains(name) {
                    last.names.append(name)
                }
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func previousCharacter(_ text: String, _ index: String.Index) -> Character? {
        guard index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    private func isKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == "-"
    }

    private func isKeyStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private func skipHorizontalSpace(_ text: String, _ start: String.Index, _ end: String.Index) -> String.Index {
        var cursor = start
        while cursor < end && (text[cursor] == " " || text[cursor] == "\t") {
            cursor = text.index(after: cursor)
        }
        return cursor
    }
}
