import Foundation

public enum GitBadgeStatus: String, CaseIterable, Sendable {
    case normal = "git.normal"
    case modified = "git.modified"
    case conflict = "git.conflict"
    case added = "git.added"
    case deleted = "git.deleted"
    case ignored = "git.ignored"
    case unversioned = "git.unversioned"

    fileprivate var priority: Int {
        switch self {
        case .conflict: 70
        case .modified: 60
        case .deleted: 55
        case .added: 50
        case .unversioned: 40
        case .ignored: 30
        case .normal: 0
        }
    }
}

public struct GitStatusSnapshot: Sendable, Equatable {
    public let repositoryRoot: URL
    public let statusesByRelativePath: [String: GitBadgeStatus]

    public init(repositoryRoot: URL, statusesByRelativePath: [String: GitBadgeStatus]) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
        self.statusesByRelativePath = statusesByRelativePath
    }

    public func status(for itemURL: URL, isDirectory: Bool) -> GitBadgeStatus? {
        let rootComponents = repositoryRoot.pathComponents
        let itemComponents = itemURL.standardizedFileURL.pathComponents
        guard itemComponents.starts(with: rootComponents) else { return nil }
        let relativePath = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return status(forRelativePath: relativePath, isDirectory: isDirectory)
    }

    public func status(forRelativePath relativePath: String, isDirectory: Bool) -> GitBadgeStatus {
        let normalized = Self.normalize(relativePath)
        var candidates: [GitBadgeStatus] = []

        if let direct = statusesByRelativePath[normalized] {
            candidates.append(direct)
        }

        // `git status --ignored=matching` can return only an ignored parent
        // directory. Apply that state to children Finder asks about.
        if !normalized.isEmpty {
            for (path, status) in statusesByRelativePath where status == .ignored || status == .unversioned {
                if !path.isEmpty && normalized.hasPrefix(path + "/") {
                    candidates.append(status)
                }
            }
        }

        if isDirectory {
            let prefix = normalized.isEmpty ? "" : normalized + "/"
            for (path, status) in statusesByRelativePath where normalized.isEmpty || path.hasPrefix(prefix) {
                candidates.append(status)
            }
        }

        return candidates.max(by: { $0.priority < $1.priority }) ?? .normal
    }

    private static func normalize(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

public enum GitPorcelainParser {
    public static func parse(_ output: String) -> [String: GitBadgeStatus] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [String: GitBadgeStatus] = [:]
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let code = String(record.prefix(2))
            let path = normalize(String(record.dropFirst(3)))
            result[path] = status(for: code)

            // In porcelain v1 `-z` output, rename/copy records are followed by
            // the original path as a separate NUL-terminated field.
            if code.contains("R") || code.contains("C") {
                index += 1
            }
            index += 1
        }
        return result
    }

    private static func status(for code: String) -> GitBadgeStatus {
        if code == "!!" { return .ignored }
        if code == "??" { return .unversioned }
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(code) { return .conflict }
        if code.contains("M") || code.contains("R") || code.contains("C") || code.contains("T") { return .modified }
        if code.contains("D") { return .deleted }
        if code.contains("A") { return .added }
        return .normal
    }

    private static func normalize(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

public struct GitStatusScanner: @unchecked Sendable {
    private let fileManager: FileManager
    private let gitExecutableURL: URL

    public init(
        fileManager: FileManager = .default,
        gitExecutableURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.gitExecutableURL = gitExecutableURL ?? Self.findGitExecutable(using: fileManager)
    }

    public func repositoryRoot(containing itemURL: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
        var candidate = exists && !isDirectory.boolValue
            ? itemURL.deletingLastPathComponent()
            : itemURL
        candidate = candidate.standardizedFileURL

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw GitStatusError.notRepository(itemURL.path)
    }

    public func snapshot(containing itemURL: URL) throws -> GitStatusSnapshot {
        let root = try repositoryRoot(containing: itemURL)
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        // `/usr/bin/git` is an xcrun shim on current macOS releases. xcrun
        // refuses to run inside an App Sandbox, so Finder extensions must
        // invoke an installed Git binary directly.
        process.executableURL = gitExecutableURL
        process.arguments = [
            "-c", "core.quotepath=false",
            "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all"
        ]
        process.currentDirectoryURL = root
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw GitStatusError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        return GitStatusSnapshot(
            repositoryRoot: root,
            statusesByRelativePath: GitPorcelainParser.parse(output)
        )
    }

    private static func findGitExecutable(using fileManager: FileManager) -> URL {
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ]
        let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) ?? "/usr/bin/git"
        return URL(fileURLWithPath: path)
    }
}

public enum GitStatusError: LocalizedError, Equatable {
    case notRepository(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRepository(let path): "Gitリポジトリが見つかりません: \(path)"
        case .commandFailed(let message): "Git状態の取得に失敗しました: \(message)"
        }
    }
}
