import AppKit

/// 网页请求权限时显示的非模态提示面板。
/// 不使用 NSAlert.runModal：在后台运行 / 全屏空间下模态弹窗可能拿不到用户选择。
final class PermissionPromptController: NSWindowController, NSWindowDelegate {

    private let completion: (Bool, Bool) -> Void
    private let rememberCheckbox = NSButton(checkboxWithTitle: "记住此站点的选择", target: nil, action: nil)
    private var finished = false

    init(host: String, permissions: [WebPermission], completion: @escaping (Bool, Bool) -> Void) {
        self.completion = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "网页权限请求"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildContent(host: host, permissions: permissions)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 初始化")
    }

    func show() {
        // accessory 应用在别的应用全屏时无法激活；临时变成常规应用，确保提示可见且可交互
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func buildContent(host: String, permissions: [WebPermission]) {
        guard let window, let contentView = window.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let joined = permissions.map { $0.requestDescription }.joined(separator: "和")
        let message = NSTextField(wrappingLabelWithString: "「\(host)」请求\(joined)")
        message.font = .boldSystemFont(ofSize: 14)
        message.widthAnchor.constraint(equalToConstant: 420).isActive = true
        root.addArrangedSubview(message)

        let detail = NSTextField(wrappingLabelWithString: "可以只允许这一次；勾选「记住此站点的选择」后会写入网页权限设置。")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.widthAnchor.constraint(equalToConstant: 420).isActive = true
        root.addArrangedSubview(detail)

        rememberCheckbox.state = .on
        root.addArrangedSubview(rememberCheckbox)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .trailing

        let denyButton = NSButton(title: "拒绝", target: self, action: #selector(denyAction))
        denyButton.bezelStyle = .rounded

        let allowButton = NSButton(title: "允许", target: self, action: #selector(allowAction))
        allowButton.bezelStyle = .rounded

        buttons.addArrangedSubview(denyButton)
        buttons.addArrangedSubview(allowButton)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
    }

    @objc private func allowAction() {
        finish(allowed: true)
    }

    @objc private func denyAction() {
        finish(allowed: false)
    }

    func windowWillClose(_ notification: Notification) {
        finish(allowed: false)
    }

    private func finish(allowed: Bool) {
        guard !finished else { return }
        finished = true
        let remember = rememberCheckbox.state == .on
        completion(allowed, remember)
        window?.delegate = nil
        close()
        NSApp.setActivationPolicy(.accessory)
    }
}
