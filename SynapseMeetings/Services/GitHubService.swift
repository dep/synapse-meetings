import Foundation

enum GitHubError: LocalizedError {
    case missingPAT
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingPAT:
            return "GitHub PAT is not set. Add it in Settings."
        case .http(let status, let body):
            return "GitHub API error (\(status)): \(body)"
        case .decoding(let detail):
            return "Could not decode GitHub response: \(detail)"
        }
    }
}

struct GitHubRepo: Identifiable, Hashable, Decodable {
    let id: Int
    let fullName: String
    let defaultBranch: String
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case defaultBranch = "default_branch"
        case isPrivate = "private"
    }
}

struct GitHubBranch: Identifiable, Hashable, Decodable {
    let name: String
    var id: String { name }
}

struct GitHubCommitResult {
    let path: String
    let sha: String
    let htmlURL: URL?
}

struct GitHubService {
    let token: String
    let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    static func makeFromKeychain() throws -> GitHubService {
        guard let token = KeychainService.shared.get(.githubPAT), !token.isEmpty else {
            throw GitHubError.missingPAT
        }
        return GitHubService(token: token)
    }

    // MARK: - Repos

    func listRepos(perPage: Int = 100) async throws -> [GitHubRepo] {
        var all: [GitHubRepo] = []
        var page = 1
        while true {
            let url = URL(string: "https://api.github.com/user/repos?per_page=\(perPage)&page=\(page)&sort=updated&affiliation=owner,collaborator,organization_member")!
            let batch: [GitHubRepo] = try await get(url: url)
            all.append(contentsOf: batch)
            if batch.count < perPage { break }
            page += 1
            if page > 10 { break } // safety guard against runaway pagination
        }
        return all
    }

    func listBranches(repoFullName: String) async throws -> [GitHubBranch] {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/branches?per_page=100")!
        return try await get(url: url)
    }

    // MARK: - Commit

    /// Creates or updates a single file in a branch via the Contents API.
    func commitFile(
        repoFullName: String,
        branch: String,
        path: String,
        contents: String,
        commitMessage: String
    ) async throws -> GitHubCommitResult {
        // 1. Look up existing sha (if any) so the API treats this as an update.
        let existingSHA = try await fileShaIfExists(repoFullName: repoFullName, path: path, branch: branch)

        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/contents/\(escape(path: path))")!
        let bodyData = Data(contents.utf8).base64EncodedString()
        var body: [String: Any] = [
            "message": commitMessage,
            "content": bodyData,
            "branch": branch
        ]
        if let existingSHA {
            body["sha"] = existingSHA
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(status: http.statusCode, body: body)
        }

        struct ContentResp: Decodable {
            struct ContentNode: Decodable {
                let path: String
                let sha: String
                let html_url: String?
            }
            let content: ContentNode
        }
        do {
            let decoded = try JSONDecoder().decode(ContentResp.self, from: data)
            return GitHubCommitResult(
                path: decoded.content.path,
                sha: decoded.content.sha,
                htmlURL: decoded.content.html_url.flatMap(URL.init(string:))
            )
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    private func fileShaIfExists(repoFullName: String, path: String, branch: String) async throws -> String? {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/contents/\(escape(path: path))")!
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        applyHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(status: http.statusCode, body: body)
        }
        struct FileNode: Decodable {
            let sha: String
        }
        return (try? JSONDecoder().decode(FileNode.self, from: data))?.sha
    }

    // MARK: - Helpers

    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SynapseMeetings/0.1", forHTTPHeaderField: "User-Agent")
    }

    private func escape(path: String) -> String {
        // GitHub expects path segments URL-encoded but slashes preserved.
        path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }
}
