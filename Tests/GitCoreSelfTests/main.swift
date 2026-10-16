import Foundation
import GitCore

private final class RecordingRunner: GitCommandRunning, @unchecked Sendable {
    struct Call: Equatable { let arguments: [String]; let directory: URL? }
    var calls: [Call] = []
    var outputs: [GitCommandResult] = []

    func run(arguments: [String], currentDirectory: URL?) throws -> GitCommandResult {
        calls.append(Call(arguments: arguments, directory: currentDirectory))
        return outputs.isEmpty
            ? GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
            : outputs.removeFirst()
    }
}

private enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): "テスト失敗: \(message)" }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestError.failed(message) }
}

private func makeRepositoryDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"), withIntermediateDirectories: true)
    return base
}

private func runTests() throws {
    do {
        let result = try GitCommandRunner().run(arguments: ["--version"], currentDirectory: nil)
        try expect(result.standardOutput.hasPrefix("git version"), "実際のgitコマンドを起動できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        let nested = base.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try GitService(runner: RecordingRunner()).repositoryRoot(containing: nested)
        try expect(root.standardizedFileURL == base.standardizedFileURL, "ネストしたフォルダからリポジトリルートを探索できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        _ = try GitService(runner: runner).commit(at: base, message: "変更を保存")
        try expect(runner.calls.map(\.arguments) == [["add", "--all"], ["commit", "--message", "変更を保存"]], "コミット前に全変更をステージしていない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "feature/test\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        _ = try GitService(runner: runner).createOrSwitchBranch(at: base, branchName: "feature/test")
        try expect(runner.calls.last?.arguments == ["switch", "feature/test"], "既存ブランチへ切り替えていない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        _ = try GitService(runner: runner).createOrSwitchBranch(at: base, branchName: "feature/new")
        try expect(runner.calls.last?.arguments == ["switch", "--create", "feature/new"], "新規ブランチを作成していない")
    }

    do {
        let runner = RecordingRunner()
        do {
            _ = try GitService(runner: runner).commit(at: URL(fileURLWithPath: "/tmp"), message: "  ")
            throw SelfTestError.failed("空のコミットメッセージを受理した")
        } catch GitServiceError.emptyCommitMessage {
            // Expected.
        }
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "main\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "テストユーザー\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "test@example.com\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "https://github.com/example/repo.git\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "git version 2.50.0\n", standardError: "")
        ]
        let settings = try GitService(runner: runner).repositorySettings(at: base)
        try expect(settings.currentBranch == "main", "現在のブランチを読み取れない")
        try expect(settings.userName == "テストユーザー", "user.nameを読み取れない")
        try expect(settings.userEmail == "test@example.com", "user.emailを読み取れない")
        try expect(settings.originURL.hasPrefix("https://github.com/"), "origin URLを読み取れない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "origin\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        try GitService(runner: runner).updateRepositorySettings(
            at: base,
            userName: "New User",
            userEmail: "new@example.com",
            originURL: "https://github.com/example/new.git"
        )
        try expect(runner.calls.last?.arguments == ["remote", "set-url", "origin", "https://github.com/example/new.git"], "既存originを更新していない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "git@github.com:example/repo.git\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "ref\tHEAD\n", standardError: "")
        ]
        _ = try GitService(runner: runner).checkGitHubConnection(at: base)
        try expect(runner.calls.last?.arguments == ["ls-remote", "origin"], "GitHub接続確認が読み取り専用になっていない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "https://github.com/example/empty.git\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "abc123\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "main\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "abc123\trefs/heads/main\n", standardError: "")
        ]
        let result = try GitService(runner: runner).checkAndInitializeGitHubRemote(at: base)
        try expect(result.initializedMain, "空のGitHubリモートを初期化していない")
        try expect(runner.calls.contains { $0.arguments == ["push", "--set-upstream", "origin", "main"] }, "mainをoriginへ送信していない")
        try expect(runner.calls.last?.arguments == ["ls-remote", "origin"], "初期化後にリモートを再確認していない")
    }

    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try GitService().initializeRepositoryDefaults(at: base)
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "Git対象フォルダを初期化していない")
        let branch = try GitCommandRunner().run(arguments: ["branch", "--show-current"], currentDirectory: root)
        try expect(branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "main", "初期ブランチがmainではない")
    }

    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = GitCommandRunner()
        _ = try runner.run(arguments: ["init", "--initial-branch=main"], currentDirectory: base)
        let service = GitService(runner: runner)
        try service.updateRepositorySettings(
            at: base,
            userName: "Integration Test",
            userEmail: "integration@example.com",
            originURL: "https://github.com/example/integration.git"
        )
        let settings = try service.repositorySettings(at: base)
        try expect(settings.userName == "Integration Test", "実リポジトリへuser.nameを保存できない")
        try expect(settings.userEmail == "integration@example.com", "実リポジトリへuser.emailを保存できない")
        try expect(settings.originURL == "https://github.com/example/integration.git", "実リポジトリへoriginを保存できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let ignoredFile = base.appendingPathComponent("build output.log")
        let ignoredDirectory = base.appendingPathComponent("Generated", isDirectory: true)
        try Data().write(to: ignoredFile)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)

        let service = GitService(runner: RecordingRunner())
        let first = try service.addToGitIgnore(items: [ignoredFile, ignoredDirectory])
        let contents = try String(contentsOf: base.appendingPathComponent(".gitignore"), encoding: .utf8)
        try expect(first.addedPatterns == ["/Generated/", "/build output.log"], ".gitignoreへ選択項目を登録できない")
        try expect(contents.contains("/Generated/\n") && contents.contains("/build output.log\n"), ".gitignoreの保存内容が正しくない")

        let second = try service.addToGitIgnore(items: [ignoredFile, ignoredDirectory])
        try expect(second.addedPatterns.isEmpty, ".gitignoreへ重複登録している")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [GitCommandResult(exitCode: 0, standardOutput: "* abc123 (HEAD -> main) Initial\n", standardError: "")]
        let result = try GitService(runner: runner).branchGraph(at: base)
        try expect(result.standardOutput.contains("main"), "ブランチ構成を取得できない")
        try expect(
            runner.calls.last?.arguments == ["log", "--all", "--graph", "--decorate", "--oneline", "--date-order", "--max-count=200"],
            "ブランチ構成のGitコマンドが正しくない"
        )
    }
}

do {
    try runTests()
    print("GitCoreSelfTest: 14件すべて成功")
} catch {
    print(error)
    exit(1)
}
