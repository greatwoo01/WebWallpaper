import AppKit

/// 网页权限设置窗口：全局默认 + 按站点覆盖。
final class PermissionsWindowController: NSWindowController {

    private let store = PermissionStore.shared
    private let currentHosts: () -> [String]
    private var siteStack: NSStackView!

    init(currentHosts: @escaping () -> [String]) {
        self.currentHosts = currentHosts
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "网页权限"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 初始化")
    }

    func reloadAndShow() {
        reloadSites()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 界面

    private func buildContent() {
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

        let globalTitle = NSTextField(labelWithString: "全局默认（未单独设置的站点使用）")
        globalTitle.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(globalTitle)

        for permission in WebPermission.allCases {
            root.addArrangedSubview(makeGlobalRow(permission))
        }

        root.addArrangedSubview(makeSeparator())

        let siteTitle = NSTextField(labelWithString: "按站点设置")
        siteTitle.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(siteTitle)
        root.addArrangedSubview(makeColumnHeader())

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // NSScrollView 的文档视图原点在左下，套一层翻转容器让内容从顶部开始排列
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        scrollView.documentView = container
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        siteStack = stack
        root.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true

        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 10
        let addButton = NSButton(title: "添加站点…", target: self, action: #selector(addSite))
        addButton.bezelStyle = .rounded
        let settingsButton = NSButton(title: "打开系统隐私设置", target: self, action: #selector(openSystemPrivacySettings))
        settingsButton.bezelStyle = .rounded
        buttonsRow.addArrangedSubview(addButton)
        buttonsRow.addArrangedSubview(settingsButton)
        root.addArrangedSubview(buttonsRow)

        root.addArrangedSubview(makeSeparator())

        let notificationsNote = makeNote(
            "网页通知：WKWebView 不支持 Web Notification / Web Push，本应用无法控制或提供网页通知，网页的通知请求不会生效。"
        )
        root.addArrangedSubview(notificationsNote)

        let systemNote = makeNote(
            "摄像头、麦克风、位置的最终授权由 macOS 管理：首次允许时系统会弹窗确认；如果之前在系统里拒绝过，请到「系统设置 → 隐私与安全性」中重新允许本应用，否则网页只会得到拒绝结果。"
        )
        root.addArrangedSubview(systemNote)

        reloadSites()
    }

    private func makeGlobalRow(_ permission: WebPermission) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let label = NSTextField(labelWithString: permission.displayName)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        row.addArrangedSubview(label)

        let popup = PolicyPopup(
            titles: PermissionPolicy.allCases.map { $0.displayName },
            selectedIndex: PermissionPolicy.allCases.firstIndex(of: store.defaultPolicy(for: permission)) ?? 0
        )
        popup.onSelect = { [weak self] index in
            guard let self, PermissionPolicy.allCases.indices.contains(index) else { return }
            self.store.setDefaultPolicy(PermissionPolicy.allCases[index], for: permission)
        }
        popup.widthAnchor.constraint(equalToConstant: 130).isActive = true
        row.addArrangedSubview(popup)
        return row
    }

    private func makeColumnHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let siteLabel = NSTextField(labelWithString: "站点")
        siteLabel.font = .systemFont(ofSize: 11)
        siteLabel.textColor = .secondaryLabelColor
        siteLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(siteLabel)

        for permission in WebPermission.allCases {
            let label = NSTextField(labelWithString: permission.displayName)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            row.addArrangedSubview(label)
        }
        return row
    }

    private func reloadSites() {
        guard let siteStack else { return }
        siteStack.arrangedSubviews.forEach {
            siteStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        var sites = Set(store.configuredSites)
        for host in currentHosts() {
            let normalized = PermissionStore.normalizedSite(host)
            if !normalized.isEmpty {
                sites.insert(normalized)
            }
        }

        if sites.isEmpty {
            let empty = NSTextField(labelWithString: "还没有站点。打开网页后会自动出现在这里，也可以点「添加站点…」。")
            empty.textColor = .secondaryLabelColor
            siteStack.addArrangedSubview(empty)
            return
        }

        for site in sites.sorted() {
            siteStack.addArrangedSubview(makeSiteRow(site))
        }
    }

    private func makeSiteRow(_ site: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let label = NSTextField(labelWithString: site)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = site
        label.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(label)

        for permission in WebPermission.allCases {
            let override = store.sitePolicies[site]?[permission]
            let titles = ["跟随默认"] + PermissionPolicy.allCases.map { $0.displayName }
            let selected = override.flatMap { PermissionPolicy.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let popup = PolicyPopup(titles: titles, selectedIndex: selected)
            popup.onSelect = { [weak self] index in
                guard let self else { return }
                let policy: PermissionPolicy? = index == 0 ? nil : PermissionPolicy.allCases[index - 1]
                self.store.setSitePolicy(policy, forSite: site, permission: permission)
                // 不要在弹出框自己的 action 里同步销毁它
                DispatchQueue.main.async { self.reloadSites() }
            }
            popup.widthAnchor.constraint(equalToConstant: 110).isActive = true
            row.addArrangedSubview(popup)
        }

        let removeButton = NSButton(title: "−", target: self, action: #selector(removeSite(_:)))
        removeButton.bezelStyle = .inline
        removeButton.toolTip = "删除该站点的设置"
        removeButton.isEnabled = store.hasOverride(forSite: site)
        removeButton.identifier = NSUserInterfaceItemIdentifier(site)
        removeButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(removeButton)

        return row
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        return box
    }

    private func makeNote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 620
        label.widthAnchor.constraint(equalToConstant: 620).isActive = true
        return label
    }

    // MARK: - 操作

    @objc private func addSite() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "添加站点"
        alert.informativeText = "输入域名或网址，例如 example.com 或 https://example.com。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = PermissionStore.normalizedSite(input)
        guard !site.isEmpty, !site.contains("/"), !site.contains(" ") else {
            presentError("无法识别的站点：\(input)")
            return
        }
        store.addSite(site)
        reloadSites()
    }

    @objc private func removeSite(_ sender: NSButton) {
        guard let site = sender.identifier?.rawValue else { return }
        store.removeSite(site)
        reloadSites()
    }

    @objc private func openSystemPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 翻转坐标系的容器，作为滚动视图文档视图时内容从顶部开始。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 带回调的下拉框，省去 target/action 的映射表。
private final class PolicyPopup: NSPopUpButton {

    var onSelect: ((Int) -> Void)?

    init(titles: [String], selectedIndex: Int) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        selectItem(at: min(max(selectedIndex, 0), titles.count - 1))
        target = self
        action = #selector(handleChange)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 初始化")
    }

    @objc private func handleChange() {
        onSelect?(indexOfSelectedItem)
    }
}
