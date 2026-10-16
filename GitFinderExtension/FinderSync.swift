import Cocoa
import FinderSync
import OSLog

final class FinderSync: FIFinderSync {
    private static let preferenceDomain = "jp.local.gitoperation"
    // Keep the persisted key for compatibility with folders selected by older builds.
    private static let gitTargetFoldersKey = "monitoredFolderPaths"
    private static let pendingRequestKey = "pendingFinderRequest"
    private let logger = Logger(subsystem: "jp.local.gitoperation.finderextension", category: "FinderSync")

    override init() {
        super.init()
        let paths = UserDefaults(suiteName: Self.preferenceDomain)?
            .stringArray(forKey: Self.gitTargetFoldersKey) ?? []
        let gitTargetFolders: Set<URL>
        if paths.isEmpty {
            // First-run bootstrap: expose the context menu without opening a
            // selection panel automatically. Once targets are registered, only
            // those folders are monitored.
            gitTargetFolders = [
                FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
                URL(fileURLWithPath: "/Volumes", isDirectory: true).standardizedFileURL
            ]
        } else {
            gitTargetFolders = Set(paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL })
        }
        FIFinderSyncController.default().directoryURLs = gitTargetFolders
        logger.notice("Configured \(gitTargetFolders.count, privacy: .public) Git target directories")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        logger.notice("Menu requested for \(String(describing: menuKind), privacy: .public)")
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }

        // Finder displays this parent item in its contextual menu. Assigning a
        // submenu makes Git operations appear as a pull-down menu for both a
        // folder's blank area and selected items.
        let root = NSMenu(title: "Git操作")
        let parent = NSMenuItem(title: "Git操作", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Git操作")

        add("リポジトリのクローン", action: #selector(cloneRepository), to: submenu)
        submenu.addItem(.separator())
        add("コミット（変更内容を保存）", action: #selector(commitChanges), to: submenu)
        add("プッシュ（リモートへ送信）", action: #selector(pushChanges), to: submenu)
        add("プル（リモートから最新版を取得）", action: #selector(pullChanges), to: submenu)
        submenu.addItem(.separator())
        add("ブランチの作成と切り替え", action: #selector(createOrSwitchBranch), to: submenu)
        add("ブランチを画像で表示…", action: #selector(showBranchGraph), to: submenu)
        submenu.addItem(.separator())
        add("Gitに登録しないファイルを追加…", action: #selector(addToGitIgnore), to: submenu)
        submenu.addItem(.separator())
        add("Git対象フォルダを追加…", action: #selector(addGitTargetFolders), to: submenu)
        add("Finder拡張機能を有効にする…", action: #selector(enableFinderExtension), to: submenu)
        add("設定…", action: #selector(openSettings), to: submenu)

        parent.submenu = submenu
        root.addItem(parent)
        return root
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func cloneRepository() { openHost(action: "clone") }
    @objc private func commitChanges() { openHost(action: "commit") }
    @objc private func pushChanges() { openHost(action: "push") }
    @objc private func pullChanges() { openHost(action: "pull") }
    @objc private func createOrSwitchBranch() { openHost(action: "branch") }
    @objc private func showBranchGraph() { openHost(action: "branchGraph") }
    @objc private func addToGitIgnore() { openHost(action: "ignore", includeAllSelectedItems: true) }
    @objc private func addGitTargetFolders() { openHost(action: "targetFolders") }
    @objc private func enableFinderExtension() { openHost(action: "enableExtension") }
    @objc private func openSettings() { openHost(action: "settings") }

    private func openHost(action: String, includeAllSelectedItems: Bool = false) {
        let controller = FIFinderSyncController.default()
        let selectedItems = controller.selectedItemURLs() ?? []
        guard let selected = selectedItems.first ?? controller.targetedURL() else { return }

        var isDirectory: ObjCBool = false
        let path: String
        if FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            path = selected.deletingLastPathComponent().path
        } else {
            path = selected.path
        }

        var request: [String: Any] = [
            "action": action,
            "path": path,
            "requestID": UUID().uuidString
        ]
        if includeAllSelectedItems {
            let items = selectedItems.isEmpty ? [selected] : selectedItems
            request["paths"] = items.map(\.path)
        }

        let defaults = UserDefaults(suiteName: Self.preferenceDomain)
        defaults?.set(request, forKey: Self.pendingRequestKey)
        defaults?.synchronize()
        let hostAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.open(hostAppURL)
    }
}
