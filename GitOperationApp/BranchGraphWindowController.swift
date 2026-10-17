import AppKit
#if canImport(GitCore)
import GitCore
#endif

private final class TopAlignedImageView: NSImageView {
    override var isFlipped: Bool { true }
}

@MainActor
final class BranchGraphWindowController: NSWindowController {
    private let service = GitService()
    private let imageView = TopAlignedImageView()
    private let scrollView = NSScrollView()
    private let repositoryLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git操作 — ブランチ構成"
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        self.init(window: window)
        configureContent()
    }

    func show(repositoryPath: String) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        repositoryLabel.stringValue = repositoryPath
        imageView.image = makeGraphImage(text: "ブランチ構成を読み込んでいます…")
        resizeDocumentForCurrentImage()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        let selectedURL = URL(fileURLWithPath: repositoryPath)
        let gitService = service
        DispatchQueue.global(qos: .userInitiated).async { [gitService, selectedURL, weak self] in
            let outcome = Result { try gitService.branchGraph(at: selectedURL) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    let graph = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.imageView.image = self.makeGraphImage(
                        text: graph.isEmpty ? "表示できるコミット履歴がありません。" : graph
                    )
                case .failure(let error):
                    self.imageView.image = self.makeGraphImage(text: "取得に失敗しました\n\n\(error.localizedDescription)")
                }
                self.resizeDocumentForCurrentImage()
            }
        }
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        repositoryLabel.font = .systemFont(ofSize: 12)
        repositoryLabel.textColor = .secondaryLabelColor
        repositoryLabel.lineBreakMode = .byTruncatingMiddle
        repositoryLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.105, alpha: 1)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageAlignment = .alignTopLeft
        imageView.imageScaling = .scaleNone
        scrollView.documentView = imageView

        contentView.addSubview(repositoryLabel)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            repositoryLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            repositoryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            repositoryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: repositoryLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func makeGraphImage(text: String) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.88, green: 0.94, blue: 1.0, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.boundingRect(
            with: NSSize(width: 3_600, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let size = NSSize(
            width: max(520, ceil(measured.width) + 48),
            height: max(300, ceil(measured.height) + 48)
        )
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.105, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        attributed.draw(in: NSRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48))
        image.unlockFocus()
        return image
    }

    private func resizeDocumentForCurrentImage() {
        guard let image = imageView.image else { return }
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
