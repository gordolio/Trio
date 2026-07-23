import Foundation
import os.log

/// Represents a partial result from streaming food analysis
struct PartialFoodAnalysisResult: Equatable {
    /// Food items parsed so far (only items with at least a name)
    var foodItems: [AIFoodItem]

    /// Reasoning text accumulated so far
    var reasoning: String

    /// Overall confidence (0 until fully parsed)
    var overallConfidence: Double

    /// Whether the stream has completed
    var isComplete: Bool
}

/// Backwards-compatible alias for the provider-agnostic parser.
typealias OpenAIStreamingParser = StructuredJSONStreamParser

/// Parses OpenAI-compatible streaming responses and extracts partial food analysis
/// results using incremental JSON parsing.
///
/// The core parser operates on an accumulated content string containing the JSON
/// fragments emitted by the model.
final class StructuredJSONStreamParser {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "StructuredJSONStreamParser")
    private let decoder = JSONDecoder()

    /// Known field types for food item objects — used to assign defaults to dangling keys
    private static let knownStringFields: Set<String> = ["name", "emoji", "reasoning", "servingUnit"]
    private static let knownNumberFields: Set<String> = ["carbs", "fat", "protein", "overallConfidence", "servingCount"]

    /// Maximum accumulated content length before we stop appending (safety cap)
    private static let maxAccumulatedLength = 100_000

    /// Accumulated JSON content string from all SSE chunks
    private var accumulatedContent = ""

    /// The last successfully parsed partial result
    private var lastResult = PartialFoodAnalysisResult(
        foodItems: [],
        reasoning: "",
        overallConfidence: 0,
        isComplete: false
    )

    // MARK: - Core Content Feed (provider-agnostic)

    /// Appends a content fragment to the accumulated JSON buffer and attempts a
    /// partial parse. Returns the updated partial result if parsing produced new
    /// content, or nil if the fragment didn't change the parsed state.
    func feed(contentDelta content: String) -> PartialFoodAnalysisResult? {
        guard !content.isEmpty else { return nil }

        guard accumulatedContent.count + content.count <= Self.maxAccumulatedLength else {
            os_log("Stream accumulated content exceeded max length, ignoring chunk", log: log, type: .error)
            return nil
        }
        accumulatedContent += content

        if let result = attemptPartialParse() {
            lastResult = result
            return result
        }
        return nil
    }

    /// Marks the stream as complete and returns the final partial result with
    /// `isComplete = true`.
    func finish() -> PartialFoodAnalysisResult {
        var result = lastResult
        result.isComplete = true
        lastResult = result
        os_log(
            "Stream complete: %d items, confidence: %.2f",
            log: log,
            type: .info,
            result.foodItems.count,
            result.overallConfidence
        )
        return result
    }

    // MARK: - OpenAI SSE Adapter

    /// Parses an SSE line from the OpenAI Chat Completions streaming format.
    /// - Parameter line: A single line from the SSE stream
    /// - Returns: Updated partial result, or nil if this line didn't produce new content
    func parseOpenAILine(_ line: String) -> PartialFoodAnalysisResult? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "data: [DONE]" {
            return finish()
        }

        guard trimmed.hasPrefix("data: ") else { return nil }
        let jsonPayload = String(trimmed.dropFirst(6))

        guard let payloadData = jsonPayload.data(using: .utf8) else { return nil }

        guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: payloadData),
              let content = chunk.choices.first?.delta.content,
              !content.isEmpty
        else { return nil }

        return feed(contentDelta: content)
    }

    /// Reset parser state for a new stream
    func reset() {
        accumulatedContent = ""
        lastResult = PartialFoodAnalysisResult(
            foodItems: [],
            reasoning: "",
            overallConfidence: 0,
            isComplete: false
        )
    }

    // MARK: - Partial JSON Parsing

    /// Attempts to parse the accumulated content as partial JSON,
    /// closing any open brackets/quotes to make it valid.
    private func attemptPartialParse() -> PartialFoodAnalysisResult? {
        let closed = closePartialJSON(accumulatedContent)
        guard let data = closed.data(using: .utf8) else { return nil }

        // Try to decode the top-level structure
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var items: [AIFoodItem] = []
        var reasoning = ""
        var confidence = 0.0

        // Extract reasoning
        if let r = dict["reasoning"] as? String {
            reasoning = r
        }

        // Extract confidence
        if let c = dict["overallConfidence"] as? Double {
            confidence = c
        }

        // Extract food items — include all objects, even partial ones
        if let foodItemsArray = dict["foodItems"] as? [[String: Any]] {
            for itemDict in foodItemsArray {
                let name = itemDict["name"] as? String ?? ""
                let carbs = itemDict["carbs"] as? Double ?? 0
                let emoji = itemDict["emoji"] as? String
                let fat = itemDict["fat"] as? Double ?? 0
                let protein = itemDict["protein"] as? Double ?? 0
                let servingCount = itemDict["servingCount"] as? Double ?? 1
                let servingUnit = itemDict["servingUnit"] as? String ?? "Serving"

                items.append(AIFoodItem(
                    name: name,
                    carbs: carbs,
                    emoji: emoji,
                    fat: fat,
                    protein: protein,
                    servingCount: servingCount,
                    servingUnit: servingUnit
                ))
            }
        }

        // Only return if we have something new to show
        let result = PartialFoodAnalysisResult(
            foodItems: items,
            reasoning: reasoning,
            overallConfidence: confidence,
            isComplete: false
        )

        // Avoid emitting duplicate results
        if result == lastResult { return nil }
        return result
    }

    // MARK: - JSON Closer

    /// Closes partial/truncated JSON by inferring missing closing tokens.
    /// Handles strings, objects, and arrays to produce parseable JSON.
    ///
    /// For example:
    ///   `{"foodItems": [{"name": "rice", "carbs": 45`
    /// becomes:
    ///   `{"foodItems": [{"name": "rice", "carbs": 45}]}`
    func closePartialJSON(_ input: String) -> String {
        var inString = false
        var escaped = false
        var stack: [Character] = [] // tracks open { and [

        for char in input {
            if escaped {
                escaped = false
                continue
            }

            if char == "\\", inString {
                escaped = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                continue
            }

            if inString { continue }

            switch char {
            case "{":
                stack.append("{")
            case "[":
                stack.append("[")
            case "}":
                if stack.last == "{" { stack.removeLast() }
            case "]":
                if stack.last == "[" { stack.removeLast() }
            default:
                break
            }
        }

        var result = input

        // If we're inside a string, close it
        if inString {
            result += "\""
        }

        // Repeatedly trim trailing invalid fragments until stable
        result = trimTrailingFragments(result)

        // Strip trailing incomplete object if it follows a complete object in an array.
        // e.g., ...},{"fat":7 → ...}  (removes the incomplete second object)
        // But [{"fat":10 stays (it's the first object, no } before it).
        result = stripTrailingIncompleteObject(result, stack: &stack)

        // Close all open brackets/braces in reverse order
        for bracket in stack.reversed() {
            result += (bracket == "{") ? "}" : "]"
        }

        return result
    }

    /// Repeatedly trims trailing fragments that would produce invalid JSON.
    /// Handles: trailing whitespace, commas, colons, incomplete key-value pairs,
    /// dangling quoted strings (partial keys without colons), and bare values
    /// missing after a colon.
    private func trimTrailingFragments(_ input: String) -> String {
        var s = input

        while true {
            let before = s

            // Strip trailing whitespace
            while s.last?.isWhitespace == true {
                s.removeLast()
            }

            guard !s.isEmpty else { break }

            // Strip trailing comma
            if s.last == "," {
                s.removeLast()
                continue
            }

            // Handle trailing colon (key with no value yet)
            // If it's a known field, add a default value. Otherwise strip.
            if s.last == ":" {
                let beforeColon = stripTrailingWhitespace(String(s.dropLast()))
                if let keyName = extractTrailingQuotedContent(beforeColon) {
                    if Self.knownStringFields.contains(keyName) {
                        s += "\"\""
                        continue
                    } else if Self.knownNumberFields.contains(keyName) {
                        s += "0"
                        continue
                    }
                }
                // Unknown key — strip the colon and key
                s.removeLast()
                s = stripTrailingWhitespace(s)
                s = stripTrailingQuotedString(s)
                s = stripTrailingWhitespace(s)
                if s.last == "," { s.removeLast() }
                continue
            }

            // Handle a dangling quoted string in key position (no colon after it)
            // If it's a known field, resolve it with a default value.
            // If it's unknown/partial, strip it.
            if s.last == "\"" {
                let candidate = stripTrailingQuotedString(s)
                let trimmedCandidate = stripTrailingWhitespace(candidate)
                // If what's left ends with , or { it was a dangling key
                if trimmedCandidate.last == "," || trimmedCandidate.last == "{" {
                    // Extract the key name (text between the quotes)
                    let keyName = extractTrailingQuotedContent(s)
                    // Check if it's a known field — if so, add default value
                    if let keyName = keyName {
                        if Self.knownStringFields.contains(keyName) {
                            s += ":\"\""
                            continue
                        } else if Self.knownNumberFields.contains(keyName) {
                            s += ":0"
                            continue
                        }
                    }
                    // Unknown/partial key — strip it
                    s = trimmedCandidate
                    if s.last == "," { s.removeLast() }
                    continue
                }
            }

            // If nothing changed, we're done
            if s == before { break }
        }

        return s
    }

    /// Removes a trailing incomplete object from an array when a complete object precedes it.
    /// Also adjusts the stack to account for removed brackets.
    private func stripTrailingIncompleteObject(_ input: String, stack: inout [Character]) -> String {
        // Must be inside an object inside an array: stack ends with [..., "[", "{"]
        guard stack.count >= 2,
              stack.last == "{",
              stack[stack.count - 2] == "["
        else { return input }

        // Find the last unmatched `{` by scanning forward
        var inStr = false
        var esc = false
        var braceStack: [String.Index] = []

        for idx in input.indices {
            let ch = input[idx]
            if esc { esc = false
                continue }
            if ch == "\\", inStr { esc = true
                continue }
            if ch == "\"" { inStr.toggle()
                continue }
            if inStr { continue }
            if ch == "{" { braceStack.append(idx) }
            if ch == "}" { if !braceStack.isEmpty { braceStack.removeLast() } }
        }

        guard let lastOpen = braceStack.last else { return input }

        // Check what's before this `{`
        var beforeSlice = input[input.startIndex ..< lastOpen]
        while beforeSlice.last?.isWhitespace == true || beforeSlice.last == "," {
            beforeSlice = beforeSlice.dropLast()
        }

        // If preceded by `}`, a complete object exists before — strip the trailing incomplete one
        if beforeSlice.last == "}" {
            // Remove the `{` from the stack since we're stripping it
            stack.removeLast()
            return String(beforeSlice)
        }

        return input
    }

    private func stripTrailingWhitespace(_ s: String) -> String {
        var s = s
        while s.last?.isWhitespace == true {
            s.removeLast()
        }
        return s
    }

    /// Extracts the content of a trailing quoted string (e.g., `"emoji"` → `"emoji"`).
    /// Returns nil if no valid quoted string is found.
    private func extractTrailingQuotedContent(_ s: String) -> String? {
        guard s.last == "\"" else { return nil }
        var temp = s
        temp.removeLast() // remove closing "
        // Find matching opening quote
        var i = temp.endIndex
        while i > temp.startIndex {
            i = temp.index(before: i)
            if temp[i] == "\"" {
                var backslashes = 0
                var j = i
                while j > temp.startIndex {
                    j = temp.index(before: j)
                    if temp[j] == "\\" { backslashes += 1 } else { break }
                }
                if backslashes % 2 == 0 {
                    let start = temp.index(after: i)
                    return String(temp[start...])
                }
            }
        }
        return nil
    }

    /// Removes a trailing quoted string (e.g., `"someKey"`) from the end.
    private func stripTrailingQuotedString(_ s: String) -> String {
        guard s.last == "\"" else { return s }
        var result = s
        result.removeLast() // remove closing "

        // Walk backwards to find the matching unescaped opening quote
        var i = result.endIndex
        while i > result.startIndex {
            i = result.index(before: i)
            if result[i] == "\"" {
                // Count preceding backslashes to check if escaped
                var backslashes = 0
                var j = i
                while j > result.startIndex {
                    j = result.index(before: j)
                    if result[j] == "\\" { backslashes += 1 } else { break }
                }
                if backslashes % 2 == 0 {
                    // Found unescaped opening quote
                    return String(result[result.startIndex ..< i])
                }
            }
        }

        return s // couldn't find matching quote, return original
    }
}
