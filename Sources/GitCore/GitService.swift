import Foundation

public enum GitAction: String, CaseIterable, Sendable {
    case clone
    case commit
    case push
    case pull
    case branch

    public var japaneseTitle: String {
        switch self {
        case .clone: "リポジトリのクローン"
        case .commit: "コミット（変更内容を保存）"
        case .push: "プッシュ（リモートへ送信）"
        case .pull: "プル（リモートから最新版を取得）"
        case .branch: "ブランチの作成と切り替え"
        }
    }
}

public struct RepositorySettings: Sendable, Equatable {
    public let repositoryRoot: URL
    public let currentBranch: String
    public let userName: String
    public let userEmail: String
    public let originURL: String
    public let gitVersion: String

    public init(repositoryRoot: URL, currentBranch: String, userName: String, userEmail: String, originURL: String, gitVersion: String) {
        self.repositoryRoot = repositoryRoot
        self.currentBranch = currentBranch
        self.userName = userName
        self.userEmail = userEmail
        self.originURL = originURL
        self.gitVersion = gitVersion
    }
}

public struct GitHubConnectionResult: Sendable, Equatable {
    public let commandResult: GitCommandResult
    public let initializedMain: Bool

    public init(commandResult: GitCommandResult, initializedMain: Bool) {
        self.commandResult = commandResult
        self.initializedMain = initializedMain
    }
}

public struct GitIgnoreUpdateResult: Sendable, Equatable {
    public let repositoryRoot: URL
    public let addedPatterns: [String]

    public init(repositoryRoot: URL, addedPatterns: [String]) {
        self.repositoryRoot = repositoryRoot
        self.addedPatterns = addedPatterns
    }
}

public struct GitService: @unchecked Sendable {
    private let runner: any GitCommandRunning
    private let fileManager: FileManager

    public init(runner: any GitCommandRunning = GitCommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    @discardableResult
    public func clone(remote: String, into parentDirectory: URL) throws -> GitCommandResult {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitServiceError.emptyRemote }
        guard parentDirectory.hasDirectoryPath || isDirectory(parentDirectory) else {
            throw GitServiceError.notDirectory(parentDirectory.path)
        }
        return try runner.run(arguments: ["clone", trimmed], currentDirectory: parentDirectory)
    }

    @discardableResult
    public func commit(at selectedURL: URL, message: String) throws -> GitCommandResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitServiceError.emptyCommitMessage }
        let root = try repositoryRoot(containing: selectedURL)
        _ = try runner.run(arguments: ["add", "--all"], currentDirectory: root)
        return try runner.run(arguments: ["commit", "--message", trimmed], currentDirectory: root)
    }

    @discardableResult
    public func push(at selectedURL: URL) throws -> GitCommandResult {
        try runner.run(arguments: ["push"], currentDirectory: repositoryRoot(containing: selectedURL))
    }

    @discardableResult
    public func pull(at selectedURL: URL) throws -> GitCommandResult {
        try runner.run(arguments: ["pull", "--ff-only"], currentDirectory: repositoryRoot(containing: selectedURL))
    }

    @discardableResult
    public func createOrSwitchBranch(at selectedURL: URL, branchName: String) throws -> GitCommandResult {
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw GitServiceError.emptyBranchName }
        let root = try repositoryRoot(containing: selectedURL)
        _ = try runner.run(arguments: ["check-ref-format", "--branch", branch], currentDirectory: root)

        let existing = try runner.run(
            arguments: ["branch", "--list", "--format=%(refname:short)", branch],
            currentDirectory: root
        ).standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        let arguments = existing.contains(branch) ? ["switch", branch] : ["switch", "--create", branch]
        return try runner.run(arguments: arguments, currentDirectory: root)
    }

    public func addToGitIgnore(items: [URL]) throws -> GitIgnoreUpdateResult {
        guard let first = items.first else { throw GitServiceError.noIgnoreItems }
        let root = try repositoryRoot(containing: first)
        let rootComponents = root.standardizedFileURL.pathComponents

        let patterns = try items.map { item -> String in
            let standardized = item.standardizedFileURL
            let components = standardized.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw GitServiceError.ignoreItemOutsideRepository(item.path)
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            guard !relative.contains("\n"), !relative.contains("\r") else {
                throw GitServiceError.invalidIgnorePath(item.path)
            }
            let suffix = isDirectory(standardized) ? "/" : ""
            return "/\(relative)\(suffix)"
        }

        let ignoreURL = root.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        let existingPatterns = Set(existing.split(whereSeparator: \.isNewline).map(String.init))
        let additions = Array(Set(patterns)).filter { !existingPatterns.contains($0) }.sorted()

        if !additions.isEmpty {
            var updated = existing
            if !updated.isEmpty && !updated.hasSuffix("\n") { updated.append("\n") }
            updated.append(additions.joined(separator: "\n"))
            updated.append("\n")
            try updated.write(to: ignoreURL, atomically: true, encoding: .utf8)
        }
        return GitIgnoreUpdateResult(repositoryRoot: root, addedPatterns: additions)
    }

    public func branchGraph(at selectedURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(containing: selectedURL)
        return try runner.run(
            arguments: ["log", "--all", "--graph", "--decorate", "--oneline", "--date-order", "--max-count=200"],
            currentDirectory: root
        )
    }

    public func repositorySettings(at selectedURL: URL) throws -> RepositorySettings {
        let root = try repositoryRoot(containing: selectedURL)
        return RepositorySettings(
            repositoryRoot: root,
            currentBranch: try output(["branch", "--show-current"], at: root),
            userName: try optionalOutput(["config", "--local", "--get", "user.name"], at: root),
            userEmail: try optionalOutput(["config", "--local", "--get", "user.email"], at: root),
            originURL: try optionalOutput(["remote", "get-url", "origin"], at: root),
            gitVersion: try output(["--version"], at: nil)
        )
    }

    /// Creates a repository when needed, uses `main` for an unborn branch, and
    /// copies inherited Git identity values into the repository-local config.
    @discardableResult
    public func initializeRepositoryDefaults(at selectedURL: URL) throws -> URL {
        guard isDirectory(selectedURL) else { throw GitServiceError.notDirectory(selectedURL.path) }

        let root: URL
        do {
            root = try repositoryRoot(containing: selectedURL)
        } catch GitServiceError.notRepository {
            _ = try runner.run(arguments: ["init", "--initial-branch=main"], currentDirectory: selectedURL)
            root = selectedURL.standardizedFileURL
        }

        let head = try optionalOutput(["rev-parse", "--verify", "HEAD"], at: root)
        let branch = try optionalOutput(["branch", "--show-current"], at: root)
        if head.isEmpty && branch != "main" {
            _ = try runner.run(arguments: ["symbolic-ref", "HEAD", "refs/heads/main"], currentDirectory: root)
        }

        try copyInheritedIdentityIfNeeded(key: "user.name", at: root)
        try copyInheritedIdentityIfNeeded(key: "user.email", at: root)
        return root
    }

    public func updateRepositorySettings(
        at selectedURL: URL,
        userName: String,
        userEmail: String,
        originURL: String
    ) throws {
        let root = try repositoryRoot(containing: selectedURL)
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GitServiceError.emptyUserName }
        guard !email.isEmpty else { throw GitServiceError.emptyUserEmail }

        _ = try runner.run(arguments: ["config", "--local", "user.name", name], currentDirectory: root)
        _ = try runner.run(arguments: ["config", "--local", "user.email", email], currentDirectory: root)

        guard !remote.isEmpty else { return }
        let remotes = try output(["remote"], at: root).split(whereSeparator: \.isNewline).map(String.init)
        let arguments = remotes.contains("origin")
            ? ["remote", "set-url", "origin", remote]
            : ["remote", "add", "origin", remote]
        _ = try runner.run(arguments: arguments, currentDirectory: root)
    }

    @discardableResult
    public func checkGitHubConnection(at selectedURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(containing: selectedURL)
        let remote = try optionalOutput(["remote", "get-url", "origin"], at: root)
        guard !remote.isEmpty else { throw GitServiceError.missingOrigin }
        guard isGitHubRemote(remote) else { throw GitServiceError.notGitHubRemote(remote) }
        // Fetch all advertised refs instead of requiring HEAD to exist. An empty
        // GitHub repository is reachable but does not advertise HEAD yet.
        return try runner.run(arguments: ["ls-remote", "origin"], currentDirectory: root)
    }

    /// Checks `origin` and, when the GitHub repository has no refs, publishes a
    /// `main` branch. Existing uncommitted files are never staged. If the local
    /// repository has no commit, an empty initial commit is created.
    public func checkAndInitializeGitHubRemote(at selectedURL: URL) throws -> GitHubConnectionResult {
        let root = try repositoryRoot(containing: selectedURL)
        let firstCheck = try checkGitHubConnection(at: root)
        guard firstCheck.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GitHubConnectionResult(commandResult: firstCheck, initializedMain: false)
        }

        let head = try optionalOutput(["rev-parse", "--verify", "HEAD"], at: root)
        var branch = try optionalOutput(["branch", "--show-current"], at: root)
        if head.isEmpty {
            if branch != "main" {
                _ = try runner.run(arguments: ["symbolic-ref", "HEAD", "refs/heads/main"], currentDirectory: root)
                branch = "main"
            }
            _ = try runner.run(
                arguments: ["commit", "--allow-empty", "--message", "Initial commit"],
                currentDirectory: root
            )
        }

        let sourceRef = branch == "main" ? "main" : "HEAD:refs/heads/main"
        _ = try runner.run(arguments: ["push", "--set-upstream", "origin", sourceRef], currentDirectory: root)
        let verification = try runner.run(arguments: ["ls-remote", "origin"], currentDirectory: root)
        guard !verification.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitServiceError.remoteStillEmpty
        }
        return GitHubConnectionResult(commandResult: verification, initializedMain: true)
    }

    public func repositoryRoot(containing selectedURL: URL) throws -> URL {
        var candidate = isDirectory(selectedURL) ? selectedURL : selectedURL.deletingLastPathComponent()
        candidate = candidate.standardizedFileURL

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw GitServiceError.notRepository(selectedURL.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func output(_ arguments: [String], at directory: URL?) throws -> String {
        try runner.run(arguments: arguments, currentDirectory: directory)
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalOutput(_ arguments: [String], at directory: URL) throws -> String {
        do {
            return try output(arguments, at: directory)
        } catch is GitCommandError {
            return ""
        }
    }

    private func copyInheritedIdentityIfNeeded(key: String, at root: URL) throws {
        let local = try optionalOutput(["config", "--local", "--get", key], at: root)
        guard local.isEmpty else { return }
        let inherited = try optionalOutput(["config", "--get", key], at: root)
        guard !inherited.isEmpty else { return }
        _ = try runner.run(arguments: ["config", "--local", key, inherited], currentDirectory: root)
    }

    private func isGitHubRemote(_ remote: String) -> Bool {
        let value = remote.lowercased()
        if let url = URL(string: value), url.host == "github.com" { return true }
        return value.hasPrefix("git@github.com:") || value.hasPrefix("ssh://git@github.com/")
    }
}

public enum GitServiceError: LocalizedError, Equatable {
    case emptyRemote
    case emptyCommitMessage
    case emptyBranchName
    case emptyUserName
    case emptyUserEmail
    case missingOrigin
    case notGitHubRemote(String)
    case notDirectory(String)
    case notRepository(String)
    case remoteStillEmpty
    case noIgnoreItems
    case ignoreItemOutsideRepository(String)
    case invalidIgnorePath(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRemote: "リモートURLを入力してください。"
        case .emptyCommitMessage: "コミットメッセージを入力してください。"
        case .emptyBranchName: "ブランチ名を入力してください。"
        case .emptyUserName: "リポジトリ用のユーザー名を入力してください。"
        case .emptyUserEmail: "リポジトリ用のメールアドレスを入力してください。"
        case .missingOrigin: "origin リモートが設定されていません。"
        case .notGitHubRemote(let remote): "origin は GitHub のURLではありません: \(remote)"
        case .notDirectory(let path): "フォルダではありません: \(path)"
        case .notRepository(let path): "Gitリポジトリが見つかりません: \(path)"
        case .remoteStillEmpty: "main を送信しましたが、リモートの参照を確認できませんでした。"
        case .noIgnoreItems: "Gitに登録しないファイルまたはフォルダを選択してください。"
        case .ignoreItemOutsideRepository(let path): "同じGitリポジトリ内の項目を選択してください: \(path)"
        case .invalidIgnorePath(let path): ".gitignoreへ登録できないファイル名です: \(path)"
        }
    }
}
