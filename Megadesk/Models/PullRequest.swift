import Foundation

struct PullRequest: Identifiable, Codable {
    let number: Int
    let title: String
    let author: PRAuthor
    let headRefName: String
    let mergeable: String        // "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
    let mergeStateStatus: String // "CLEAN" | "BEHIND" | "BLOCKED" | "DIRTY" | "UNKNOWN"
    let statusCheckRollup: [StatusCheck]
    let url: String
    let updatedAt: String

    var id: Int { number }
    var hasConflicts: Bool { mergeable == "CONFLICTING" }
    var isBehindMain: Bool { mergeStateStatus == "BEHIND" }
    var shortBranch: String { headRefName.components(separatedBy: "/").last ?? headRefName }

    enum CIStatus { case pending, passing, failing, none }
    var ciStatus: CIStatus {
        guard !statusCheckRollup.isEmpty else { return .none }
        if statusCheckRollup.contains(where: {
            ["FAILURE", "ERROR", "TIMED_OUT"].contains($0.conclusion ?? "")
        }) { return .failing }
        if statusCheckRollup.contains(where: {
            $0.conclusion == nil || ["PENDING", "IN_PROGRESS"].contains($0.state ?? "")
        }) { return .pending }
        return .passing
    }
}

struct PRAuthor: Codable { let login: String }
struct StatusCheck: Codable { let state: String?; let conclusion: String? }

struct TrackedPR: Identifiable {
    let repo: String    // "owner/repo"
    let number: Int     // PR number
    var data: PullRequest?
    var fetchState: FetchState = .idle

    var id: String { "\(repo)#\(number)" }

    enum FetchState: Equatable {
        case idle, loading, loaded, error(String)
    }

    /// Parses "owner/repo#123" or "https://github.com/owner/repo/pull/123".
    static func parse(_ input: String) -> (repo: String, number: Int)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Normalize GitHub URL → owner/repo/pull/123
        var path = trimmed
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] {
            if trimmed.lowercased().hasPrefix(prefix) {
                path = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        let parts = path.components(separatedBy: "/")
        if parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) {
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
