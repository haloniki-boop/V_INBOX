import Foundation
import GitCore

private enum IntegrationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): "統合テスト失敗: \(message)"
        }
    }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw IntegrationError.failed(message) }
}

private let runner = GitCommandRunner()

@discardableResult
private func git(_ arguments: [String], at directory: URL?) throws -> GitCommandResult {
    try runner.run(arguments: arguments, currentDirectory: directory)
}

private func output(_ arguments: [String], at directory: URL?) throws -> String {
    try git(arguments, at: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func configureIdentity(at directory: URL) throws {
    _ = try git(["config", "user.name", "GitOperation Integration Test"], at: directory)
    _ = try git(["config", "user.email", "integration@example.invalid"], at: directory)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func checkpoint(_ name: String, _ results: inout [String]) {
    results.append(name)
    print("✓ \(name)")
}

private func runIntegrationTests() throws -> [String] {
    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory
        .appendingPathComponent("GitOperationIntegration-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sandbox) }

    let service = GitService()
    var results: [String] = []

    let initialized = sandbox.appendingPathComponent("Initialized", isDirectory: true)
    try fileManager.createDirectory(at: initialized, withIntermediateDirectories: true)
    _ = try service.createRepository(at: initialized)
    try expect(try output(["branch", "--show-current"], at: initialized) == "main", "リポジトリ初期化のmainではない")
    checkpoint("ここにリポジトリを作成", &results)

    let remote = sandbox.appendingPathComponent("origin.git", isDirectory: true)
    _ = try git(["init", "--bare", "--initial-branch=main", remote.path], at: sandbox)

    let seed = sandbox.appendingPathComponent("Seed", isDirectory: true)
    try fileManager.createDirectory(at: seed, withIntermediateDirectories: true)
    _ = try git(["init", "--initial-branch=main"], at: seed)
    try configureIdentity(at: seed)
    try write("base\n", to: seed.appendingPathComponent("base.txt"))
    _ = try git(["add", "base.txt"], at: seed)
    _ = try git(["commit", "-m", "base"], at: seed)
    _ = try git(["remote", "add", "origin", remote.path], at: seed)
    _ = try git(["push", "-u", "origin", "main"], at: seed)

    let clientParent = sandbox.appendingPathComponent("ClientA", isDirectory: true)
    let peerParent = sandbox.appendingPathComponent("ClientB", isDirectory: true)
    try fileManager.createDirectory(at: clientParent, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: peerParent, withIntermediateDirectories: true)
    _ = try service.clone(remote: remote.path, into: clientParent)
    _ = try service.clone(remote: remote.path, into: peerParent)
    let client = clientParent.appendingPathComponent("origin", isDirectory: true)
    let peer = peerParent.appendingPathComponent("origin", isDirectory: true)
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent(".git").path), "クローン先が作成されていない")
    checkpoint("リポジトリのクローン", &results)
    try configureIdentity(at: client)
    try configureIdentity(at: peer)

    _ = try service.fetch(at: client)
    checkpoint("フェッチ", &results)

    try write("local commit\n", to: client.appendingPathComponent("local.txt"))
    _ = try service.commit(at: client, message: "local commit")
    _ = try service.push(at: client)
    try expect(try output(["show", "main:local.txt"], at: remote) == "local commit", "プッシュした内容がリモートにない")
    checkpoint("コミット", &results)
    checkpoint("プッシュ", &results)

    _ = try git(["pull", "--ff-only"], at: peer)
    try write("upstream\n", to: peer.appendingPathComponent("upstream.txt"))
    _ = try git(["add", "upstream.txt"], at: peer)
    _ = try git(["commit", "-m", "upstream"], at: peer)
    _ = try git(["push"], at: peer)
    _ = try service.pull(at: client)
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent("upstream.txt").path), "プルでファイルが取得されていない")
    checkpoint("プル", &results)

    try write("sync\n", to: client.appendingPathComponent("sync.txt"))
    _ = try service.commit(at: client, message: "sync")
    _ = try service.sync(at: client)
    try expect(try output(["show", "main:sync.txt"], at: remote) == "sync", "同期内のPushが反映されていない")
    checkpoint("同期（Fetch → Pull → Push）", &results)

    try write("changed\n", to: client.appendingPathComponent("base.txt"))
    let status = try service.status(at: client).standardOutput
    let diff = try service.diff(at: client, items: [client.appendingPathComponent("base.txt")]).standardOutput
    try expect(status.contains("base.txt"), "変更の確認に変更ファイルがない")
    try expect(diff.contains("changed"), "差分表示に変更内容がない")
    checkpoint("変更の確認", &results)
    checkpoint("差分を表示", &results)
    _ = try service.commit(at: client, message: "change base")
    let previousDiff = try service.diffWithPreviousVersion(at: client, items: [client.appendingPathComponent("base.txt")]).standardOutput
    try expect(previousDiff.contains("changed"), "前版との差分が表示されない")
    checkpoint("前版との差分", &results)

    let log = try service.showLog(at: client).standardOutput
    let graph = try service.branchGraph(at: client).standardOutput
    try expect(log.contains("change base"), "ログに最新コミットがない")
    try expect(graph.contains("main"), "ブランチグラフにmainがない")
    checkpoint("ログを表示", &results)
    checkpoint("ブランチを画像で表示するデータ取得", &results)

    let added = client.appendingPathComponent("added.txt")
    try write("added\n", to: added)
    _ = try service.add(at: client, items: [added])
    try expect(try output(["status", "--short", "added.txt"], at: client).hasPrefix("A"), "Git追加後にステージされていない")
    checkpoint("Gitに追加", &results)
    _ = try service.commit(at: client, message: "add file")

    _ = try service.rename(at: client, item: added, destination: "renamed.txt")
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent("renamed.txt").path), "名前変更が反映されていない")
    checkpoint("名前変更・移動", &results)
    _ = try service.commit(at: client, message: "rename file")

    let renamed = client.appendingPathComponent("renamed.txt")
    try write("temporary change\n", to: renamed)
    _ = try service.revert(at: client, items: [renamed])
    try expect(try String(contentsOf: renamed, encoding: .utf8) == "added\n", "元に戻す操作が変更を破棄していない")
    checkpoint("元に戻す", &results)

    let ignored = client.appendingPathComponent("Generated/output.log")
    try write("ignore\n", to: ignored)
    _ = try service.addToGitIgnore(items: [ignored])
    try expect(try output(["check-ignore", "Generated/output.log"], at: client).contains("Generated/output.log"), ".gitignoreが反映されていない")
    checkpoint("Gitに登録しないファイルを追加", &results)
    _ = try service.commit(at: client, message: "ignore generated")

    let removed = client.appendingPathComponent("remove.txt")
    try write("remove\n", to: removed)
    _ = try service.commit(at: client, message: "add removable")
    _ = try service.remove(at: client, items: [removed])
    try expect(!fileManager.fileExists(atPath: removed.path), "Gitから削除後もファイルが残っている")
    checkpoint("Gitから削除", &results)
    _ = try service.commit(at: client, message: "remove file")

    _ = try service.createBranch(at: client, branchName: "feature/integration")
    try expect(try output(["branch", "--show-current"], at: client) == "feature/integration", "ブランチが作成・切り替えされていない")
    checkpoint("ブランチを作成", &results)
    _ = try service.switchBranch(at: client, branchName: "main")
    try expect(try output(["branch", "--show-current"], at: client) == "main", "mainへ切り替えられない")
    checkpoint("ブランチを切り替え", &results)

    _ = try service.switchBranch(at: client, branchName: "feature/integration")
    try write("feature\n", to: client.appendingPathComponent("feature.txt"))
    _ = try service.commit(at: client, message: "feature")
    _ = try service.switchBranch(at: client, branchName: "main")
    _ = try service.merge(at: client, branch: "feature/integration")
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent("feature.txt").path), "マージ内容が作業ツリーにない")
    checkpoint("マージ", &results)

    _ = try service.createBranch(at: client, branchName: "feature/rebase")
    try write("rebase\n", to: client.appendingPathComponent("rebase.txt"))
    _ = try service.commit(at: client, message: "rebase work")
    _ = try service.switchBranch(at: client, branchName: "main")
    try write("main advance\n", to: client.appendingPathComponent("main-advance.txt"))
    _ = try service.commit(at: client, message: "main advance")
    _ = try service.switchBranch(at: client, branchName: "feature/rebase")
    _ = try service.rebase(at: client, branch: "main")
    try expect(try output(["merge-base", "--is-ancestor", "main", "HEAD"], at: client).isEmpty, "リベース後にmainが祖先ではない")
    checkpoint("リベース", &results)
    _ = try service.switchBranch(at: client, branchName: "main")

    let headBeforeReset = try output(["rev-parse", "HEAD"], at: client)
    try write("reset\n", to: client.appendingPathComponent("reset.txt"))
    _ = try service.commit(at: client, message: "reset target")
    _ = try service.reset(at: client, reference: headBeforeReset)
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent("reset.txt").path), "mixed resetが作業ファイルを残していない")
    checkpoint("リセット（mixed）", &results)
    _ = try service.commit(at: client, message: "restore reset file")

    try write("stash change\n", to: client.appendingPathComponent("base.txt"))
    try write("stash untracked\n", to: client.appendingPathComponent("stash-untracked.txt"))
    _ = try service.stashSave(at: client, message: "integration stash")
    try expect(try output(["status", "--short"], at: client).isEmpty, "スタッシュ保存後に作業ツリーが汚れている")
    checkpoint("スタッシュに保存", &results)
    _ = try service.stashPop(at: client)
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent("stash-untracked.txt").path), "スタッシュ復元で未追跡ファイルが戻らない")
    checkpoint("スタッシュを復元", &results)
    _ = try service.commit(at: client, message: "commit restored stash")

    _ = try service.createTag(at: client, name: "integration-v1")
    try expect(try output(["tag", "--list", "integration-v1"], at: client) == "integration-v1", "タグが作成されていない")
    checkpoint("タグを作成", &results)

    let blame = try service.blame(at: client, item: client.appendingPathComponent("base.txt")).standardOutput
    try expect(blame.contains("GitOperation Integration Test"), "Blameに変更者が表示されない")
    checkpoint("行ごとの変更者を表示", &results)

    let patchParent = sandbox.appendingPathComponent("PatchTarget", isDirectory: true)
    try fileManager.createDirectory(at: patchParent, withIntermediateDirectories: true)
    _ = try service.clone(remote: client.path, into: patchParent)
    let patchTarget = patchParent.appendingPathComponent("origin", isDirectory: true)
    try configureIdentity(at: patchTarget)
    try write("patch content\n", to: client.appendingPathComponent("patch-content.txt"))
    _ = try service.commit(at: client, message: "patch content")
    let patchResult = try service.createPatch(at: client, range: "-1")
    guard let patchName = patchResult.standardOutput.split(whereSeparator: \.isNewline).last.map(String.init) else {
        throw IntegrationError.failed("作成されたパッチ名を取得できない")
    }
    let patchURL = client.appendingPathComponent(patchName)
    try expect(fileManager.fileExists(atPath: patchURL.path), "パッチファイルが作成されていない")
    checkpoint("パッチを作成", &results)
    _ = try service.applyPatch(at: patchTarget, patchURL: patchURL)
    try expect(fileManager.fileExists(atPath: patchTarget.appendingPathComponent("patch-content.txt").path), "パッチが適用されていない")
    checkpoint("パッチを適用", &results)

    let submoduleSource = sandbox.appendingPathComponent("SubmoduleSource", isDirectory: true)
    try fileManager.createDirectory(at: submoduleSource, withIntermediateDirectories: true)
    _ = try git(["init", "--initial-branch=main"], at: submoduleSource)
    try configureIdentity(at: submoduleSource)
    try write("submodule\n", to: submoduleSource.appendingPathComponent("sub.txt"))
    _ = try git(["add", "sub.txt"], at: submoduleSource)
    _ = try git(["commit", "-m", "submodule"], at: submoduleSource)
    _ = try git(["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource.path, "Modules/Sub"], at: client)
    _ = try service.commit(at: client, message: "add submodule")
    try fileManager.removeItem(at: client.appendingPathComponent("Modules/Sub"))
    _ = try git(["config", "protocol.file.allow", "always"], at: client)
    _ = try service.updateSubmodules(at: client)
    try expect(fileManager.fileExists(atPath: client.appendingPathComponent("Modules/Sub/sub.txt").path), "サブモジュールが復元されていない")
    checkpoint("サブモジュールを更新", &results)

    _ = try service.bisect(at: client, arguments: "start")
    _ = try service.bisect(at: client, arguments: "bad HEAD")
    _ = try service.bisect(at: client, arguments: "good HEAD~1")
    _ = try service.bisect(at: client, arguments: "reset")
    checkpoint("Bisect", &results)

    let cleanupFile = client.appendingPathComponent("cleanup.tmp")
    let cleanupDirectory = client.appendingPathComponent("CleanupDirectory", isDirectory: true)
    try write("cleanup\n", to: cleanupFile)
    try fileManager.createDirectory(at: cleanupDirectory, withIntermediateDirectories: true)
    try write("cleanup\n", to: cleanupDirectory.appendingPathComponent("item.txt"))
    _ = try service.cleanup(at: client)
    try expect(!fileManager.fileExists(atPath: cleanupFile.path), "Cleanupで未追跡ファイルが削除されていない")
    try expect(!fileManager.fileExists(atPath: cleanupDirectory.path), "Cleanupで未追跡フォルダが削除されていない")
    checkpoint("Cleanup", &results)

    let settings = try service.repositorySettings(at: client)
    try expect(settings.currentBranch == "main", "設定から現在のブランチを読み取れない")
    try expect(settings.userName == "GitOperation Integration Test", "設定からユーザー名を読み取れない")
    try expect(settings.originURL == remote.path, "設定からoriginを読み取れない")
    checkpoint("リポジトリ設定の読み取り", &results)

    return results
}

do {
    let results = try runIntegrationTests()
    print("GitCoreIntegrationTest: \(results.count)機能すべて成功")
} catch {
    print(error)
    exit(1)
}
