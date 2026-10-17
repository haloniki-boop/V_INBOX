import AppKit
import FinderSync
import OSLog
import ServiceManagement
#if canImport(GitCore)
import GitCore
#endif

private let galleryStatusTagPrefix = "Git状態: "

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let preferenceDomain = "jp.local.gitoperation"
    // Keep the persisted key for compatibility with folders selected by older builds.
    private static let gitTargetFoldersKey = "monitoredFolderPaths"
    private static let pendingRequestKey = "pendingFinderRequest"
    private static let pendingBadgePathsKey = "pendingBadgePaths"
    private static let badgeStatusCacheKey = "gitBadgeStatusCache"
    private static let pendingBadgeDirectoriesKey = "pendingBadgeDirectories"
    private static let badgeDirectoryCacheKey = "gitBadgeDirectoryCache"
    private static let getURLEventClass: AEEventClass = 0x4755_524C // 'GURL'
    private static let getURLEventID: AEEventID = 0x4755_524C // 'GURL'
    private static let directObjectKeyword: AEKeyword = 0x2D2D_2D2D // '----'
    private lazy var settingsWindowController = SettingsWindowController()
    private lazy var branchGraphWindowController = BranchGraphWindowController()
    private let service = GitService()
    private let badgeScanner = GitStatusScanner()
    private let logger = Logger(subsystem: "jp.local.gitoperation", category: "App")
    private var finderRequestTimer: Timer?
    private var statusItem: NSStatusItem?

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: Self.getURLEventClass,
            andEventID: Self.getURLEventID
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerURLHandler()
        configureStatusItem()
        processPendingFinderRequest()
        processPendingBadgeRequests()
        processPendingBadgeDirectoryRequests()
        finderRequestTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(pollFinderRequests),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        processPendingFinderRequest()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        processPendingFinderRequest()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        route(urls)
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: Self.directObjectKeyword)?.stringValue,
              let url = URL(string: value) else {
            logger.error("Received an invalid URL Apple event")
            return
        }
        logger.notice("Received URL Apple event")
        route([url])
    }

    private func route(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        if let settingsURL = urls.first(where: { $0.scheme == "gitoperation" && $0.host == "settings" }) {
            let path = URLComponents(url: settingsURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
            logger.notice("Received settings URL")
            DispatchQueue.main.async { [self] in
                settingsWindowController.show(repositoryPath: path)
            }
            return
        }
        guard let request = urls.compactMap(GitOperationRequest.init(url:)).first else { return }
        OperationCoordinator.shared.perform(request.action, at: request.path)
    }

    @discardableResult
    private func processPendingFinderRequest() -> Bool {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        guard let request = CFPreferencesCopyAppValue(Self.pendingRequestKey as CFString, domain) as? [String: Any],
              let action = request["action"] as? String,
              let path = request["path"] as? String else { return false }
        CFPreferencesSetAppValue(Self.pendingRequestKey as CFString, nil, domain)
        CFPreferencesAppSynchronize(domain)

        if action == "settings" {
            logger.notice("Received settings request from Finder")
            settingsWindowController.show(repositoryPath: path)
        } else if action == "ignore" {
            logger.notice("Received .gitignore request from Finder")
            let paths = request["paths"] as? [String] ?? [path]
            OperationCoordinator.shared.addToGitIgnore(paths: paths)
        } else if action == "branchGraph" {
            logger.notice("Received branch graph request from Finder")
            branchGraphWindowController.show(repositoryPath: path)
        } else if action == "targetFolders" {
            logger.notice("Received Git target folder request from Finder")
            chooseGitTargetFolders()
        } else if action == "enableExtension" {
            logger.notice("Received Finder extension settings request")
            showFinderExtensionSettings()
        } else if action == "about" {
            logger.notice("Received About request from Finder")
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        } else if let gitAction = GitAction(rawValue: action) {
            let paths = request["paths"] as? [String] ?? []
            OperationCoordinator.shared.perform(gitAction, at: path, selectedPaths: paths)
        }
        return true
    }

    @objc private func pollFinderRequests() {
        processPendingFinderRequest()
        processPendingBadgeRequests()
        processPendingBadgeDirectoryRequests()
    }

    private func processPendingBadgeRequests() {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        guard let requests = CFPreferencesCopyAppValue(Self.pendingBadgePathsKey as CFString, domain) as? [String: String],
              !requests.isEmpty else { return }
        CFPreferencesSetAppValue(Self.pendingBadgePathsKey as CFString, nil, domain)
        CFPreferencesAppSynchronize(domain)

        let scanner = badgeScanner
        let logger = logger
        DispatchQueue.global(qos: .utility).async {
            var snapshots: [String: GitStatusSnapshot] = [:]
            var resolved: [String: String] = [:]

            for (path, requestID) in requests {
                do {
                    let url = URL(fileURLWithPath: path)
                    let root = try scanner.repositoryRoot(containing: url)
                    let snapshot: GitStatusSnapshot
                    if let existing = snapshots[root.path] {
                        snapshot = existing
                    } else {
                        snapshot = try scanner.snapshot(containing: root)
                        snapshots[root.path] = snapshot
                    }
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    if let status = snapshot.status(for: url, isDirectory: isDirectory.boolValue) {
                        resolved[path] = requestID + "\t" + status.rawValue
                    }
                } catch {
                    logger.error("Badge scan failed for \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }

            guard !resolved.isEmpty else { return }
            CFPreferencesAppSynchronize(domain)
            var cache = CFPreferencesCopyAppValue(Self.badgeStatusCacheKey as CFString, domain) as? [String: String] ?? [:]
            cache.merge(resolved) { _, new in new }
            CFPreferencesSetAppValue(Self.badgeStatusCacheKey as CFString, cache as CFDictionary, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    private func processPendingBadgeDirectoryRequests() {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        guard let requests = CFPreferencesCopyAppValue(Self.pendingBadgeDirectoriesKey as CFString, domain)
                as? [String: String],
              !requests.isEmpty else { return }
        CFPreferencesSetAppValue(Self.pendingBadgeDirectoriesKey as CFString, nil, domain)
        CFPreferencesAppSynchronize(domain)

        let scanner = badgeScanner
        let logger = logger
        DispatchQueue.global(qos: .utility).async {
            var responses: [String: [String: String]] = [:]
            for (directoryPath, requestID) in requests {
                var values: [String: String] = ["__requestID": requestID]
                do {
                    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
                    let children = try FileManager.default.contentsOfDirectory(
                        at: directoryURL,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                    let root = try scanner.repositoryRoot(containing: directoryURL)
                    let snapshot = try scanner.snapshot(containing: root)
                    for child in children {
                        let valuesForURL = try child.resourceValues(forKeys: [.isDirectoryKey])
                        if let status = snapshot.status(for: child, isDirectory: valuesForURL.isDirectory == true) {
                            values[child.path] = status.rawValue
                            do {
                                try Self.updateGalleryStatusTag(status, for: child)
                            } catch {
                                logger.error(
                                    "Gallery status update failed for \(child.path, privacy: .public): \(String(describing: error), privacy: .public)"
                                )
                            }
                        }
                    }
                } catch {
                    logger.error(
                        "Directory badge scan failed for \(directoryPath, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
                responses[directoryPath] = values
            }

            CFPreferencesAppSynchronize(domain)
            var cache = CFPreferencesCopyAppValue(Self.badgeDirectoryCacheKey as CFString, domain)
                as? [String: [String: String]] ?? [:]
            cache.merge(responses) { _, new in new }
            CFPreferencesSetAppValue(Self.badgeDirectoryCacheKey as CFString, cache as CFDictionary, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    /// Finder Sync does not expose a gallery-preview metadata API. Finder's
    /// built-in Tags field is available in the gallery information pane, so
    /// publish the current Git state there while preserving the user's tags.
    nonisolated private static func updateGalleryStatusTag(_ status: GitBadgeStatus, for itemURL: URL) throws {
        let currentTags = try itemURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        var updatedTags = currentTags.filter { !$0.hasPrefix(galleryStatusTagPrefix) }
        updatedTags.append(galleryStatusTagPrefix + galleryStatusName(for: status))
        guard updatedTags != currentTags else { return }

        // NSURL's resource-value setter is available on every supported macOS
        // release; URLResourceValues.tagNames became writable only in a much
        // newer SDK despite Finder tags themselves being longstanding.
        try (itemURL as NSURL).setResourceValue(updatedTags, forKey: .tagNamesKey)
    }

    nonisolated private static func galleryStatusName(for status: GitBadgeStatus) -> String {
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

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "arrow.triangle.branch",
                accessibilityDescription: "Git操作"
            ) ?? NSImage(named: NSImage.actionTemplateName)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Git操作"
        }

        let menu = NSMenu(title: "Git操作")
        addStatusMenuItem("Git対象フォルダを追加…", action: #selector(addGitTargetFolderFromStatusItem), to: menu)
        addStatusMenuItem("Finder拡張機能を有効にする…", action: #selector(enableFinderExtensionFromStatusItem), to: menu)
        addStatusMenuItem("設定…", action: #selector(openSettingsFromStatusItem), to: menu)
        menu.addItem(.separator())
        addStatusMenuItem("Git操作を終了", action: #selector(quitFromStatusItem), to: menu)
        item.menu = menu
        statusItem = item
    }

    private func addStatusMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func addGitTargetFolderFromStatusItem() {
        chooseGitTargetFolders()
    }

    @objc private func enableFinderExtensionFromStatusItem() {
        showFinderExtensionSettings()
    }

    private func showFinderExtensionSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    @objc private func openSettingsFromStatusItem() {
        settingsWindowController.show(repositoryPath: nil)
    }

    @objc private func quitFromStatusItem() {
        NSApp.terminate(nil)
    }

    private func chooseGitTargetFolders() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Git対象フォルダを選択"
        panel.prompt = "Git対象に追加"
        panel.message = "Gitの初期値を登録します。originが設定済みで空の場合は、未コミットファイルを含めず初期リポジトリ（main）を登録します。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let defaults = UserDefaults(suiteName: Self.preferenceDomain)
        let existing = defaults?.stringArray(forKey: Self.gitTargetFoldersKey) ?? []
        let selected = panel.urls.map { $0.standardizedFileURL.path }
        let combined = Array(Set(existing + selected)).sorted()
        defaults?.set(combined, forKey: Self.gitTargetFoldersKey)
        defaults?.synchronize()

        initializeGitTargets(panel.urls)
    }

    private func initializeGitTargets(_ urls: [URL]) {
        let progress = NSAlert()
        progress.messageText = "Git対象フォルダを初期設定中…"
        progress.informativeText = "ローカル設定とGitHubリモートを確認しています。"
        progress.addButton(withTitle: "閉じる")

        let service = service
        DispatchQueue.global(qos: .userInitiated).async {
            var initializedMain: [String] = []
            var missingOrigin: [String] = []
            var failures: [String] = []

            for url in urls {
                do {
                    let root = try service.initializeRepositoryDefaults(at: url)
                    do {
                        let result = try service.checkAndInitializeGitHubRemote(at: root)
                        if result.initializedMain { initializedMain.append(root.path) }
                    } catch GitServiceError.missingOrigin {
                        missingOrigin.append(root.path)
                    } catch {
                        failures.append("\(root.path): \(error.localizedDescription)")
                    }
                } catch {
                    failures.append("\(url.path): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                progress.window.orderOut(nil)
                let alert = NSAlert()
                if failures.isEmpty {
                    alert.messageText = "Git対象フォルダを登録しました"
                } else {
                    alert.alertStyle = .warning
                    alert.messageText = "一部の初期設定を完了できませんでした"
                }

                var details = ["Finderを開き直すと、右クリックメニューに「Git操作」が表示されます。"]
                if !initializedMain.isEmpty {
                    details.append("初期リポジトリ（main）を登録: \(initializedMain.joined(separator: ", "))")
                }
                if !missingOrigin.isEmpty {
                    details.append("origin未設定（設定画面で登録してください）: \(missingOrigin.joined(separator: ", "))")
                }
                details.append(contentsOf: failures)
                alert.informativeText = details.joined(separator: "\n")
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        progress.window.center()
        progress.window.makeKeyAndOrderFront(nil)
    }
}

private struct GitOperationRequest {
    let action: GitAction
    let path: String

    init?(url: URL) {
        guard url.scheme == "gitoperation",
              let host = url.host,
              let action = GitAction(rawValue: host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/") else { return nil }
        self.action = action
        self.path = path
    }
}

@MainActor
private final class OperationCoordinator {
    static let shared = OperationCoordinator()
    private let service = GitService()

    func perform(_ action: GitAction, at path: String, selectedPaths: [String] = []) {
        NSApp.activate(ignoringOtherApps: true)
        let selectedURL = URL(fileURLWithPath: path)
        let items = selectedPaths.map { URL(fileURLWithPath: $0) }
        switch action {
        case .clone:
            guard let remote = prompt(title: action.japaneseTitle, message: "クローンするリポジトリのURLを入力してください。", placeholder: "https://github.com/example/repository.git") else { return }
            let destination = directoryURL(for: selectedURL)
            run(action: action) { try self.service.clone(remote: remote, into: destination) }
        case .sync:
            guard confirm(title: action.japaneseTitle, message: "Fetch → fast-forward Pull → Push の順に同期しますか？") else { return }
            run(action: action) { try self.service.sync(at: selectedURL) }
        case .commit:
            guard let message = prompt(title: action.japaneseTitle, message: "すべての変更をステージしてコミットします。\nコミットメッセージを入力してください。", placeholder: "変更内容") else { return }
            run(action: action) { try self.service.commit(at: selectedURL, message: message) }
        case .push:
            guard confirm(title: action.japaneseTitle, message: "現在のブランチを設定済みのリモートへプッシュしますか？") else { return }
            run(action: action) { try self.service.push(at: selectedURL) }
        case .pull:
            guard confirm(title: action.japaneseTitle, message: "fast-forward のみでリモートの最新版を取得しますか？") else { return }
            run(action: action) { try self.service.pull(at: selectedURL) }
        case .fetch:
            run(action: action) { try self.service.fetch(at: selectedURL) }
        case .showLog:
            run(action: action) { try self.service.showLog(at: selectedURL) }
        case .status:
            run(action: action) { try self.service.status(at: selectedURL) }
        case .diff:
            run(action: action) { try self.service.diff(at: selectedURL, items: items) }
        case .diffPrevious:
            run(action: action) { try self.service.diffWithPreviousVersion(at: selectedURL, items: items) }
        case .add:
            run(action: action) { try self.service.add(at: selectedURL, items: items) }
        case .remove:
            guard confirm(title: action.japaneseTitle, message: "選択項目をGitと作業フォルダから削除します。続けますか？") else { return }
            run(action: action) { try self.service.remove(at: selectedURL, items: items) }
        case .rename:
            guard let item = items.first,
                  let destination = prompt(
                    title: action.japaneseTitle,
                    message: "リポジトリのルートからの移動先パスを入力してください。",
                    placeholder: item.lastPathComponent
                  ) else { return }
            run(action: action) { try self.service.rename(at: selectedURL, item: item, destination: destination) }
        case .revert:
            guard confirm(title: action.japaneseTitle, message: "選択項目のステージ済み・未コミットの変更を破棄します。この操作は元に戻せません。") else { return }
            run(action: action) { try self.service.revert(at: selectedURL, items: items) }
        case .createBranch:
            guard let branch = prompt(title: action.japaneseTitle, message: "新しいブランチを作成し、そのブランチへ切り替えます。", placeholder: "feature/my-change") else { return }
            run(action: action) { try self.service.createBranch(at: selectedURL, branchName: branch) }
        case .switchBranch:
            guard let branch = prompt(title: action.japaneseTitle, message: "切り替える既存ブランチ名を入力してください。", placeholder: "main") else { return }
            run(action: action) { try self.service.switchBranch(at: selectedURL, branchName: branch) }
        case .merge:
            guard let branch = prompt(title: action.japaneseTitle, message: "現在のブランチへマージするブランチ名を入力してください。", placeholder: "feature/my-change"),
                  confirm(title: action.japaneseTitle, message: "\(branch) を現在のブランチへマージしますか？") else { return }
            run(action: action) { try self.service.merge(at: selectedURL, branch: branch) }
        case .rebase:
            guard let branch = prompt(title: action.japaneseTitle, message: "リベース先のブランチ名を入力してください。", placeholder: "main"),
                  confirm(title: action.japaneseTitle, message: "コミット履歴が書き換わる可能性があります。続けますか？") else { return }
            run(action: action) { try self.service.rebase(at: selectedURL, branch: branch) }
        case .reset:
            guard let reference = prompt(title: action.japaneseTitle, message: "mixed resetの移動先を入力してください。作業ファイルは保持されます。", placeholder: "HEAD~1"),
                  confirm(title: action.japaneseTitle, message: "ブランチの位置とステージ状態を変更します。続けますか？") else { return }
            run(action: action) { try self.service.reset(at: selectedURL, reference: reference) }
        case .stashSave:
            guard let message = prompt(title: action.japaneseTitle, message: "未追跡ファイルを含む変更を一時保存します。メッセージは省略可能です。", placeholder: "作業途中") else { return }
            run(action: action) { try self.service.stashSave(at: selectedURL, message: message) }
        case .stashPop:
            guard confirm(title: action.japaneseTitle, message: "最新のスタッシュを復元してスタッシュ一覧から削除しますか？") else { return }
            run(action: action) { try self.service.stashPop(at: selectedURL) }
        case .createTag:
            guard let tag = prompt(title: action.japaneseTitle, message: "現在のコミットに付けるタグ名を入力してください。", placeholder: "v1.0.0") else { return }
            run(action: action) { try self.service.createTag(at: selectedURL, name: tag) }
        case .blame:
            guard let item = items.first else { return }
            run(action: action) { try self.service.blame(at: selectedURL, item: item) }
        case .createPatch:
            guard let range = prompt(title: action.japaneseTitle, message: "git format-patch に渡す範囲を入力してください。パッチはリポジトリ直下に作成されます。", placeholder: "origin/main..HEAD") else { return }
            run(action: action) { try self.service.createPatch(at: selectedURL, range: range) }
        case .applyPatch:
            guard let patchURL = choosePatchFile() else { return }
            guard confirm(title: action.japaneseTitle, message: "\(patchURL.lastPathComponent) を3-wayマージで適用しますか？") else { return }
            run(action: action) { try self.service.applyPatch(at: selectedURL, patchURL: patchURL) }
        case .submoduleUpdate:
            run(action: action) { try self.service.updateSubmodules(at: selectedURL) }
        case .createRepository:
            let directory = directoryURL(for: selectedURL)
            guard confirm(title: action.japaneseTitle, message: "\(directory.path) をmainブランチのGitリポジトリとして初期化しますか？") else { return }
            run(action: action) { try self.service.createRepository(at: directory) }
        case .bisect:
            guard let command = prompt(title: action.japaneseTitle, message: "start / good [commit] / bad [commit] / skip / reset を入力してください。", placeholder: "start") else { return }
            run(action: action) { try self.service.bisect(at: selectedURL, arguments: command) }
        case .cleanup:
            guard confirm(title: action.japaneseTitle, message: "未追跡のファイルとフォルダを完全に削除します。この操作は元に戻せません。") else { return }
            run(action: action) { try self.service.cleanup(at: selectedURL) }
        }
    }

    func addToGitIgnore(paths: [String]) {
        NSApp.activate(ignoringOtherApps: true)
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let progress = NSAlert()
        progress.messageText = ".gitignoreへ登録中…"
        progress.informativeText = "選択したファイルまたはフォルダをGitの管理対象外にします。"
        progress.addButton(withTitle: "閉じる")

        let service = service
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try service.addToGitIgnore(items: urls) }
            DispatchQueue.main.async {
                progress.window.orderOut(nil)
                switch outcome {
                case .success(let result):
                    if result.addedPatterns.isEmpty {
                        self.showResult(
                            title: "登録済みです",
                            text: "選択した項目は、すでに .gitignore に登録されています。"
                        )
                    } else {
                        self.showResult(
                            title: "Gitの管理対象外に登録しました",
                            text: result.addedPatterns.joined(separator: "\n")
                        )
                    }
                case .failure(let error):
                    self.showResult(title: "登録に失敗しました", text: error.localizedDescription, style: .critical)
                }
            }
        }
        progress.window.center()
        progress.window.makeKeyAndOrderFront(nil)
    }

    private func directoryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private func choosePatchFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "適用するパッチを選択"
        panel.prompt = "選択"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func run(action: GitAction, operation: @escaping @Sendable () throws -> GitCommandResult) {
        let progress = NSAlert()
        progress.messageText = "\(action.japaneseTitle)を実行中…"
        progress.informativeText = "完了するまで少しお待ちください。"
        progress.addButton(withTitle: "閉じる")

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try operation() }
            DispatchQueue.main.async {
                progress.window.orderOut(nil)
                switch outcome {
                case .success(let result):
                    self.showResult(title: "完了", text: result.combinedOutput.isEmpty ? "操作が完了しました。" : result.combinedOutput)
                case .failure(let error):
                    self.showResult(title: "Git操作に失敗しました", text: error.localizedDescription, style: .critical)
                }
            }
        }
        progress.window.center()
        progress.window.makeKeyAndOrderFront(nil)
    }

    private func prompt(title: String, message: String, placeholder: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = placeholder
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: "実行")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "実行")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showResult(title: String, text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = String(text.prefix(8_000))
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
