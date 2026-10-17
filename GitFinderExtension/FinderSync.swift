import Cocoa
import FinderSync
import OSLog

private enum FinderGitAction: String {
    case clone, sync, commit, push, pull, fetch
    case showLog, status, diff, diffPrevious
    case add, remove, rename, revert
    case createBranch, switchBranch, merge, rebase, reset
    case stashSave, stashPop, createTag, blame
    case createPatch, applyPatch, submoduleUpdate
    case createRepository, bisect, cleanup
}

final class FinderSync: FIFinderSync {
    private static let preferenceDomain = "jp.local.gitoperation"
    // Keep the persisted key for compatibility with folders selected by older builds.
    private static let gitTargetFoldersKey = "monitoredFolderPaths"
    private static let pendingRequestKey = "pendingFinderRequest"
    private let logger = Logger(subsystem: "jp.local.gitoperation.finderextension", category: "FinderSync")
    private let badgeService = GitBadgeService()

    override init() {
        super.init()
        registerBadgeImages()
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
        ensureHostAppIsRunning()
    }

    override func requestBadgeIdentifier(for url: URL) {
        logger.notice("Badge requested for \(url.path, privacy: .public)")
        resolveAndSetBadge(for: url)
    }

    override func beginObservingDirectory(at url: URL) {
        logger.notice("Started observing \(url.path, privacy: .public)")
        // Gallery view does not always ask for badges item-by-item. Resolve the
        // visible directory's immediate children when observation starts. The
        // host uses the same result to publish Git state in Gallery's Tags
        // information field; icon, list and column views use badge identifiers.
        badgeService.badgeStatuses(in: url) { statuses in
            let controller = FIFinderSyncController.default()
            for (itemURL, status) in statuses {
                controller.setBadgeIdentifier(status.rawValue, for: itemURL)
            }
        }
    }

    private func resolveAndSetBadge(for url: URL) {
        let requestLogger = logger
        badgeService.badgeStatus(for: url) { status in
            let statusIdentifier = status?.rawValue ?? "none"
            requestLogger.notice(
                "Badge resolved for \(url.path, privacy: .public): \(statusIdentifier, privacy: .public)"
            )
            FIFinderSyncController.default().setBadgeIdentifier(status?.rawValue ?? "", for: url)
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        logger.notice("Menu requested for \(String(describing: menuKind), privacy: .public)")
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }

        let root = NSMenu(title: "Git操作")
        let parent = NSMenuItem(title: "Git操作", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Git操作")

        let controller = FIFinderSyncController.default()
        let selectedItems = controller.selectedItemURLs() ?? []
        guard let target = selectedItems.first ?? controller.targetedURL() else { return nil }
        let managed = isInsideRepository(target)
        let hasSelection = !selectedItems.isEmpty
        let isSingleFile = selectedItems.count == 1 && !isDirectory(selectedItems[0])

        if managed {
            let remote = category("同期・リモート操作", in: submenu)
            addAction("同期", .sync, to: remote)
            addAction("プル", .pull, to: remote)
            addAction("プッシュ", .push, to: remote)
            addAction("フェッチ", .fetch, to: remote)
            addAction("クローン…", .clone, to: remote)

            let commit = category("コミット関連", in: submenu)
            addAction("コミット…", .commit, to: commit)
            addAction("ログを表示", .showLog, to: commit)
            addAction("変更の確認", .status, to: commit)
            addAction("差分を表示", .diff, to: commit)
            addAction("前版との差分", .diffPrevious, to: commit)

            let worktree = category("作業ツリー操作", in: submenu)
            addAction("追加", .add, to: worktree, enabled: hasSelection)
            addAction("削除", .remove, to: worktree, enabled: hasSelection)
            addAction("名前変更・移動…", .rename, to: worktree, enabled: selectedItems.count == 1)
            addAction("元に戻す", .revert, to: worktree, enabled: hasSelection)
            add("Gitに登録しないファイルを追加…", action: #selector(addToGitIgnore), to: worktree, enabled: hasSelection)

            let history = category("ブランチ・履歴操作", in: submenu)
            addAction("ブランチを作成…", .createBranch, to: history)
            addAction("ブランチを切り替え…", .switchBranch, to: history)
            addAction("マージ…", .merge, to: history)
            addAction("リベース…", .rebase, to: history)
            addAction("リセット…", .reset, to: history)
            addAction("スタッシュに保存…", .stashSave, to: history)
            addAction("スタッシュを復元", .stashPop, to: history)
            addAction("タグを作成…", .createTag, to: history)
            addAction("行ごとの変更者を表示", .blame, to: history, enabled: isSingleFile)
            add("ブランチを画像で表示…", action: #selector(showBranchGraph), to: history)

            let patch = category("パッチ・サブモジュール", in: submenu)
            addAction("パッチを作成…", .createPatch, to: patch)
            addAction("パッチを適用…", .applyPatch, to: patch)
            addAction("サブモジュールを更新", .submoduleUpdate, to: patch)

            if NSEvent.modifierFlags.contains(.shift) {
                let advanced = category("高度な操作", in: submenu)
                addAction("Bisect…", .bisect, to: advanced)
                addAction("Cleanup（未追跡ファイルを削除）…", .cleanup, to: advanced)
            }
        } else {
            addAction("リポジトリのクローン…", .clone, to: submenu, enabled: isDirectory(target))
            addAction("ここにリポジトリを作成", .createRepository, to: submenu, enabled: isDirectory(target))
        }

        submenu.addItem(.separator())
        add("Git対象フォルダを追加…", action: #selector(addGitTargetFolders), to: submenu)
        add("Finder拡張機能を有効にする…", action: #selector(enableFinderExtension), to: submenu)
        add("設定…", action: #selector(openSettings), to: submenu)
        add("バージョン情報", action: #selector(showAbout), to: submenu)

        parent.submenu = submenu
        root.addItem(parent)
        return root
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: FinderGitAction, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: #selector(performGitAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @discardableResult
    private func category(_ title: String, in menu: NSMenu) -> NSMenu {
        let child = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = child
        menu.addItem(item)
        return child
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private func isInsideRepository(_ url: URL) -> Bool {
        var candidate = isDirectory(url) ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) { return true }
            candidate.deleteLastPathComponent()
        }
        return false
    }

    private func registerBadgeImages() {
        let controller = FIFinderSyncController.default()
        for status in GitBadgeStatus.allCases {
            controller.setBadgeImage(
                Self.badgeImage(for: status),
                label: Self.badgeLabel(for: status),
                forBadgeIdentifier: status.rawValue
            )
        }
    }

    private func ensureHostAppIsRunning() {
        let hostAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.open(hostAppURL)
    }

    private static func badgeLabel(for status: GitBadgeStatus) -> String {
        switch status {
        case .normal: "正常"
        case .modified: "変更あり"
        case .conflict: "競合"
        case .added: "追加済み"
        case .deleted: "削除予定"
        case .ignored: "Git管理対象外"
        case .unversioned: "未登録"
        }
    }

    private static func badgeImage(for status: GitBadgeStatus) -> NSImage {
        // Finder renders the registered image in icon, list and column views.
        // Supply a high-resolution source so compact rows remain crisp.
        let scale: CGFloat = 10
        let size = NSSize(width: 32 * scale, height: 32 * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

        let color: NSColor
        switch status {
        case .normal: color = NSColor(calibratedRed: 0.12, green: 0.68, blue: 0.29, alpha: 1)
        case .modified: color = NSColor(calibratedRed: 0.88, green: 0.16, blue: 0.16, alpha: 1)
        case .conflict: color = NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.08, alpha: 1)
        case .added: color = NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.92, alpha: 1)
        case .deleted: color = NSColor(calibratedRed: 0.72, green: 0.12, blue: 0.18, alpha: 1)
        case .ignored: color = NSColor(calibratedWhite: 0.43, alpha: 1)
        case .unversioned: color = NSColor(calibratedWhite: 0.55, alpha: 1)
        }

        let circleRect = NSRect(x: 2.5, y: 2.5, width: 27, height: 27)
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()

        if status == .normal {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 8, y: 16))
            check.line(to: NSPoint(x: 13.5, y: 10.5))
            check.line(to: NSPoint(x: 24, y: 22))
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.lineWidth = 3.5
            NSColor.white.setStroke()
            check.stroke()
        } else if status == .ignored {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 9, y: 9))
            slash.line(to: NSPoint(x: 23, y: 23))
            slash.lineCapStyle = .round
            slash.lineWidth = 3.5
            NSColor.white.setStroke()
            slash.stroke()
        } else {
            let symbol: String
            switch status {
            case .modified, .conflict: symbol = "!"
            case .added: symbol = "+"
            case .deleted: symbol = "−"
            case .unversioned: symbol = "?"
            case .normal, .ignored: symbol = ""
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let symbolColor: NSColor = status == .conflict
                ? NSColor(calibratedWhite: 0.18, alpha: 1)
                : .white
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .heavy),
                .foregroundColor: symbolColor,
                .paragraphStyle: paragraph
            ]
            symbol.draw(in: NSRect(x: 3, y: 4.5, width: 26, height: 24), withAttributes: attributes)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func performGitAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        openHost(action: action, includeAllSelectedItems: true)
    }
    @objc private func showBranchGraph() { openHost(action: "branchGraph") }
    @objc private func addToGitIgnore() { openHost(action: "ignore", includeAllSelectedItems: true) }
    @objc private func addGitTargetFolders() { openHost(action: "targetFolders") }
    @objc private func enableFinderExtension() { openHost(action: "enableExtension") }
    @objc private func openSettings() { openHost(action: "settings") }
    @objc private func showAbout() { openHost(action: "about") }

    private func openHost(action: String, includeAllSelectedItems: Bool = false) {
        let controller = FIFinderSyncController.default()
        let selectedItems = controller.selectedItemURLs() ?? []
        guard let selected = selectedItems.first ?? controller.targetedURL() else { return }

        var request: [String: Any] = [
            "action": action,
            "path": selected.path,
            "requestID": UUID().uuidString
        ]
        if includeAllSelectedItems {
            request["paths"] = selectedItems.map(\.path)
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
