import Foundation

/// Which test request the iPhone sent, so the approval says it's a test.
enum AIRequestTestKind: String, Codable {
    /// Goes through every check, then reports the dose it would give. Nothing is logged or given.
    case dryRun
    /// Logs the carbs and gives Trio's real dose, like an assistant's request.
    case real
}
