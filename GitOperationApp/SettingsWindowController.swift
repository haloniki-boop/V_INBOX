import AppKit
import OSLog
#if canImport(GitCore)
import GitCore
#endif

@MainActor
final class SettingsWindowController: NSWindowController {
    private let service = GitService()
    private let logger = Logger(subsystem: "jp.local.gitoperation", category: "Settings")
    private var repositoryURL: URL?

    private let repositoryLabel = NSTextField(labelWithString: "未選択")
    private let branchLabel = NSTextField(labelWithString: "—")
    private let gitVersionLabel = NSTextField(labelWithString: "—")
    private let userNameField = NSTextField()
    private let userEmailField = NSTextField()
    private let originField = NSTextField()
    private let connectionLabel = NSTextField(labelWithString: "未確認")
    private let saveButton = NSButton(title: "設定を保存", target: nil, action: nil)
    private let checkButton = NSButton(title: "GitHub接続を確認", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.title = "Git操作 — 設定"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        buildContent()
    }

    func show(repositoryPath: String? = nil) {
        logger.notice("Showing settings window")
        NSApp.activate(ignoringOtherApps: true)
        guard let window else {
            logger.error("Settings window is unavailable")
            return
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let repositoryPath {
            loadRepository(URL(fileURLWithPath: repositoryPath))
        } else {
            clearRepositorySelection()
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "リポジトリ設定")
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(heading)

        let choose = NSButton(title: "対象リポジトリを選択…", target: self, action: #selector(chooseRepository))
        stack.addArrangedSubview(choose)
        stack.addArrangedSubview(row(label: "リポジトリ", control: repositoryLabel))
        stack.addArrangedSubview(row(label: "現在のブランチ", control: branchLabel))
        stack.addArrangedSubview(row(label: "Git", control: gitVersionLabel))
        stack.addArrangedSubview(row(label: "ユーザー名", control: userNameField))
        stack.addArrangedSubview(row(label: "メール", control: userEmailField))
        originField.placeholderString = "https://github.com/owner/repository.git"
        stack.addArrangedSubview(row(label: "origin URL", control: originField))

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        checkButton.target = self
        checkButton.action = #selector(checkGitHubConnection)
        actions.addArrangedSubview(saveButton)
        actions.addArrangedSubview(checkButton)
        stack.addArrangedSubview(actions)

        connectionLabel.textColor = .secondaryLabelColor
        connectionLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(row(label: "GitHub接続", control: connectionLabel))

        let note = NSTextField(wrappingLabelWithString: "設定は選択したリポジトリの .git/config に保存します。画面表示時にGitHub接続を確認し、空のリモートには未コミットファイルを含めず main を初期登録します。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        stack.addArrangedSubview(note)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        setEnabled(false)
    }

    private func row(label: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 120).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 470).isActive = true
        row.addArrangedSubview(title)
        row.addArrangedSubview(control)
        return row
    }

    @objc private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Gitリポジトリ内のフォルダを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadRepository(url)
    }

    private func loadRepository(_ url: URL) {
        do {
            let settings = try service.repositorySettings(at: url)
            repositoryURL = settings.repositoryRoot
            repositoryLabel.stringValue = settings.repositoryRoot.path
            branchLabel.stringValue = settings.currentBranch.isEmpty ? "（detached HEAD）" : settings.currentBranch
            gitVersionLabel.stringValue = settings.gitVersion
            userNameField.stringValue = settings.userName
            userEmailField.stringValue = settings.userEmail
            originField.stringValue = settings.originURL
            connectionLabel.stringValue = "未確認"
            connectionLabel.textColor = .secondaryLabelColor
            setEnabled(true)
            verifyGitHubConnection()
        } catch {
            showError(error)
        }
    }

    @objc private func saveSettings() {
        guard let repositoryURL else { return }
        do {
            try service.updateRepositorySettings(
                at: repositoryURL,
                userName: userNameField.stringValue,
                userEmail: userEmailField.stringValue,
                originURL: originField.stringValue
            )
            loadRepository(repositoryURL)
            showMessage("設定を保存しました", detail: "このリポジトリだけに適用されます。")
        } catch {
            showError(error)
        }
    }

    @objc private func checkGitHubConnection() {
        verifyGitHubConnection()
    }

    private func verifyGitHubConnection() {
        guard let repositoryURL else { return }
        checkButton.isEnabled = false
        connectionLabel.stringValue = "確認中…"
        let service = service
        DispatchQueue.global(qos: .userInitiated).async { [self, service, repositoryURL] in
            let outcome = Result { try service.checkAndInitializeGitHubRemote(at: repositoryURL) }
            DispatchQueue.main.async {
                self.checkButton.isEnabled = true
                switch outcome {
                case .success(let result):
                    if result.initializedMain {
                        self.connectionLabel.stringValue = "接続成功 — 空のリモートへ初期リポジトリ（main）を登録しました"
                    } else {
                        self.connectionLabel.stringValue = "接続成功 — origin の参照を取得できました"
                    }
                    self.connectionLabel.textColor = .systemGreen
                case .failure(let error):
                    self.connectionLabel.stringValue = "接続失敗 — \(error.localizedDescription)"
                    self.connectionLabel.textColor = .systemRed
                }
            }
        }
    }

    private func clearRepositorySelection() {
        repositoryURL = nil
        repositoryLabel.stringValue = "未選択"
        branchLabel.stringValue = "—"
        gitVersionLabel.stringValue = "—"
        userNameField.stringValue = ""
        userEmailField.stringValue = ""
        originField.stringValue = ""
        connectionLabel.stringValue = "未確認"
        connectionLabel.textColor = .secondaryLabelColor
        setEnabled(false)
    }

    private func setEnabled(_ enabled: Bool) {
        userNameField.isEnabled = enabled
        userEmailField.isEnabled = enabled
        originField.isEnabled = enabled
        saveButton.isEnabled = enabled
        checkButton.isEnabled = enabled
    }

    private func showError(_ error: Error) {
        showMessage("設定を読み込めません", detail: error.localizedDescription, style: .critical)
    }

    private func showMessage(_ title: String, detail: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }
}
