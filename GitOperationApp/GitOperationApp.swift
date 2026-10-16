import AppKit
import FinderSync
import OSLog
#if canImport(GitCore)
import GitCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let preferenceDomain = "jp.local.gitoperation"
    // Keep the persisted key for compatibility with folders selected by older builds.
    private static let gitTargetFoldersKey = "monitoredFolderPaths"
    private static let pendingRequestKey = "pendingFinderRequest"
    private static let getURLEventClass: AEEventClass = 0x4755_524C // 'GURL'
    private static let getURLEventID: AEEventID = 0x4755_524C // 'GURL'
    private static let directObjectKeyword: AEKeyword = 0x2D2D_2D2D // '----'
    private lazy var settingsWindowController = SettingsWindowController()
    private lazy var branchGraphWindowController = BranchGraphWindowController()
    private let service = GitService()
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
            FIFinderSyncController.showExtensionManagementInterface()
        } else if let gitAction = GitAction(rawValue: action) {
            OperationCoordinator.shared.perform(gitAction, at: path)
        }
        return true
    }

    @objc private func pollFinderRequests() {
        processPendingFinderRequest()
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
        FIFinderSyncController.showExtensionManagementInterface()
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

    func perform(_ action: GitAction, at path: String) {
        NSApp.activate(ignoringOtherApps: true)
        let selectedURL = URL(fileURLWithPath: path)
        switch action {
        case .clone:
            guard let remote = prompt(title: action.japaneseTitle, message: "クローンするリポジトリのURLを入力してください。", placeholder: "https://github.com/example/repository.git") else { return }
            run(action: action) { try self.service.clone(remote: remote, into: selectedURL) }
        case .commit:
            guard let message = prompt(title: action.japaneseTitle, message: "すべての変更をステージしてコミットします。\nコミットメッセージを入力してください。", placeholder: "変更内容") else { return }
            run(action: action) { try self.service.commit(at: selectedURL, message: message) }
        case .push:
            guard confirm(title: action.japaneseTitle, message: "現在のブランチを設定済みのリモートへプッシュしますか？") else { return }
            run(action: action) { try self.service.push(at: selectedURL) }
        case .pull:
            guard confirm(title: action.japaneseTitle, message: "fast-forward のみでリモートの最新版を取得しますか？") else { return }
            run(action: action) { try self.service.pull(at: selectedURL) }
        case .branch:
            guard let branch = prompt(title: action.japaneseTitle, message: "既存のブランチ名なら切り替え、存在しなければ新規作成します。", placeholder: "feature/my-change") else { return }
            run(action: action) { try self.service.createOrSwitchBranch(at: selectedURL, branchName: branch) }
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
