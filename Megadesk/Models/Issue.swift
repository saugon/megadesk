import Foundation

struct Issue: Identifiable, Codable {
    let number: Int
    let title: String
    let author: IssueAuthor
    let body: String
    let state: String            // "OPEN" | "CLOSED"
    let stateReason: String?     // "COMPLETED" | "NOT_PLANNED" | "REOPENED" | null
    let labels: [IssueLabel]
    let url: String
    let updatedAt: String

    var id: Int { number }
    var isOpen: Bool { state == "OPEN" }
    var isClosed: Bool { state == "CLOSED" }
    var isNotPlanned: Bool { stateReason == "NOT_PLANNED" }
    var truncatedBody: String { body.count <= 2000 ? body : String(body.prefix(2000)) + "..." }
}

struct IssueAuthor: Codable { let login: String }
struct IssueLabel: Codable { let name: String; let color: String }  // color is hex without "#"

struct TrackedIssue: Identifiable {
    let repo: String    // "owner/repo"
    let number: Int     // issue number
    var data: Issue?
    var fetchState: IssueFetchState = .idle

    var id: String { "\(repo)#\(number)" }

    enum IssueFetchState: Equatable {
        case idle, loading, loaded, error(String)
    }

    /// Parses "owner/repo#123" or "https://github.com/owner/repo/issues/123".
    static func parse(_ input: String) -> (repo: String, number: Int)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Normalize GitHub URL → owner/repo/issues/123
        var path = trimmed
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] {
            if trimmed.lowercased().hasPrefix(prefix) {
                path = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        let parts = path.components(separatedBy: "/")
        if parts.count >= 4, parts[2] == "issues", let n = Int(parts[3]) {
            return ("\(parts[0])/\(parts[1])", n)
        }

        // owner/repo#123
        let hashParts = trimmed.components(separatedBy: "#")
        if hashParts.count == 2,
           let n = Int(hashParts[1].trimmingCharacters(in: .whitespaces)) {
            return (hashParts[0].trimmingCharacters(in: .whitespaces), n)
        }

        return nil
    }
}
