import AppKit
import CoreGraphics
import CoreLocation
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var windows: [WallpaperWindow] = []
    private var windowsByScreenID: [String: WallpaperWindow] = [:]
    private var statusItem: NSStatusItem?

    private var manualPaused = false
    private var screensAsleep = false
    private var sessionInactive = false

    private let permissionStore = PermissionStore.shared
    private let locationService = LocationService.shared
    private let permissionBridge = PermissionBridge()
    private var permissionsWindowController: PermissionsWindowController?
    /// 每个 WebView 正在进行的定位订阅：webView -> (消息 id -> token)
    private var locationWatches: [ObjectIdentifier: [Int: UUID]] = [:]
    /// 当前展示中的权限询问面板（同一时间只弹一个）
    private var promptQueue: [() -> Void] = []
    private var activePermissionPrompt: PermissionPromptController?

    /// 默认网址：未单独设置网址的屏幕都使用它（沿用旧版本的单网址键，自动迁移）
    private static let defaultURLKey = "WebWallpaper.currentURL"
    /// 每块屏幕各自的网址，键为屏幕的稳定标识（显示器 UUID）
    private static let screenURLsKey = "WebWallpaper.screenURLs"
    /// 被停用网页壁纸的屏幕标识集合
    private static let disabledScreensKey = "WebWallpaper.disabledScreenIDs"

    private var defaultURL: URL? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.defaultURLKey) else { return nil }
            return URL(string: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: Self.defaultURLKey)
        }
    }

    private var screenURLs: [String: String] = [:]
    private var disabledScreenIDs: Set<String> = []

    private var isPaused: Bool {
        manualPaused || screensAsleep || sessionInactive
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        permissionBridge.handler = { [weak self] message in
            self?.handleGeolocationMessage(message)
        }
        loadScreenURLs()
        loadDisabledScreens()
        setupMainMenu()
        createWindows()
        setupStatusItem()
        registerObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 屏幕与网址

    private func loadScreenURLs() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.screenURLsKey) else { return }
        screenURLs = stored.compactMapValues { $0 as? String }
    }

    private func saveScreenURLs() {
        UserDefaults.standard.set(screenURLs, forKey: Self.screenURLsKey)
    }

    private func loadDisabledScreens() {
        disabledScreenIDs = Set(UserDefaults.standard.stringArray(forKey: Self.disabledScreensKey) ?? [])
    }

    private func saveDisabledScreens() {
        UserDefaults.standard.set(Array(disabledScreenIDs), forKey: Self.disabledScreensKey)
    }

    private func screen(forScreenID id: String) -> NSScreen? {
        NSScreen.screens.first { ScreenIdentity.identifier(for: $0) == id }
    }

    private func url(forScreenID id: String) -> URL? {
        if let raw = screenURLs[id], let url = URL(string: raw) {
            return url
        }
        return defaultURL
    }

    private func createWindows() {
        windows.forEach {
            $0.unload()
            $0.close()
        }
        windows.removeAll()
        windowsByScreenID.removeAll()

        for screen in NSScreen.screens {
            let screenID = ScreenIdentity.identifier(for: screen)
            // 停用的屏幕直接不建窗口，不加载网页、不占 WebContent 进程
            guard !disabledScreenIDs.contains(screenID) else { continue }
            let window = makeWallpaperWindow(screen: screen)
            window.load(url(forScreenID: screenID))
            window.orderFrontRegardless()
            windows.append(window)
            windowsByScreenID[screenID] = window
        }
        applyPauseState()
    }

    private func makeWallpaperWindow(screen: NSScreen) -> WallpaperWindow {
        let window = WallpaperWindow(screen: screen, permissionBridge: permissionBridge)
        window.onNavigationStarted = { [weak self, weak webView = window.webView] in
            guard let self, let webView else { return }
            self.clearLocationWatches(for: webView)
        }
        window.onUnload = { [weak self, weak webView = window.webView] in
            guard let self, let webView else { return }
            self.clearLocationWatches(for: webView)
        }
        window.onMediaCapturePermission = { [weak self] origin, type, decisionHandler in
            self?.handleMediaCapture(origin: origin, type: type, decisionHandler: decisionHandler)
        }
        return window
    }

    // MARK: - 主菜单

    /// 菜单栏应用默认没有主菜单，没有「编辑」菜单时 Cmd+C / Cmd+V 等
    /// 快捷键不会被分发，弹窗里的输入框也就无法复制粘贴。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于网页壁纸",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出网页壁纸",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 状态栏菜单

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "网页壁纸")
            button.toolTip = "网页壁纸"
        }

        let menu = NSMenu()
        menu.delegate = self
        rebuildStatusMenu(menu)

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    /// 每次打开菜单时重建，保证屏幕列表、各屏当前网址和暂停状态都是最新的
    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let defaultItem = NSMenuItem(
            title: "默认网址：\(displayText(for: defaultURL))",
            action: nil,
            keyEquivalent: ""
        )
        defaultItem.isEnabled = false
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        for (index, screen) in NSScreen.screens.enumerated() {
            let screenID = ScreenIdentity.identifier(for: screen)
            let enabled = !disabledScreenIDs.contains(screenID)
            let status = enabled ? displayText(for: url(forScreenID: screenID)) : "已停用"
            let item = NSMenuItem(
                title: "\(index + 1). \(screen.localizedName) — \(status)",
                action: nil,
                keyEquivalent: ""
            )
            item.submenu = makeScreenMenu(screenID: screenID, enabled: enabled)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let setDefaultItem = NSMenuItem(
            title: "设置默认网址…",
            action: #selector(promptForDefaultURL),
            keyEquivalent: "u"
        )
        setDefaultItem.target = self
        menu.addItem(setDefaultItem)

        let reloadItem = NSMenuItem(title: "全部重新载入", action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let pauseItem = NSMenuItem(
            title: manualPaused ? "恢复" : "暂停",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let permissionsItem = NSMenuItem(
            title: "网页权限…",
            action: #selector(showPermissions),
            keyEquivalent: ","
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func makeScreenMenu(screenID: String, enabled: Bool) -> NSMenu {
        let submenu = NSMenu()

        let toggleItem = NSMenuItem(
            title: "启用网页壁纸",
            action: #selector(toggleScreenEnabled(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.representedObject = screenID
        toggleItem.state = enabled ? .on : .off
        submenu.addItem(toggleItem)

        submenu.addItem(.separator())

        let current = url(forScreenID: screenID)
        let infoItem = NSMenuItem(
            title: enabled ? "当前：\(current?.absoluteString ?? "默认页面")" : "当前：已停用（显示系统壁纸）",
            action: nil,
            keyEquivalent: ""
        )
        infoItem.isEnabled = false
        submenu.addItem(infoItem)

        let setItem = NSMenuItem(
            title: "设置此屏幕网址…",
            action: #selector(promptForScreenURL(_:)),
            keyEquivalent: ""
        )
        setItem.target = self
        setItem.representedObject = screenID
        submenu.addItem(setItem)

        let useDefaultItem = NSMenuItem(
            title: "使用默认网址",
            action: #selector(useDefaultURL(_:)),
            keyEquivalent: ""
        )
        useDefaultItem.target = self
        useDefaultItem.representedObject = screenID
        useDefaultItem.isEnabled = screenURLs[screenID] != nil
        submenu.addItem(useDefaultItem)

        return submenu
    }

    // MARK: - 每屏启用/停用

    @objc private func toggleScreenEnabled(_ sender: NSMenuItem) {
        guard let screenID = sender.representedObject as? String else { return }
        if disabledScreenIDs.contains(screenID) {
            enableScreen(screenID)
        } else {
            disableScreen(screenID)
        }
    }

    private func disableScreen(_ screenID: String) {
        disabledScreenIDs.insert(screenID)
        saveDisabledScreens()

        // 关闭窗口以释放该屏的 WKWebView / WebContent 进程，露出系统壁纸
        if let window = windowsByScreenID.removeValue(forKey: screenID) {
            window.unload()
            window.close()
            windows.removeAll { $0 === window }
        }
    }

    private func enableScreen(_ screenID: String) {
        guard let screen = screen(forScreenID: screenID) else { return }

        disabledScreenIDs.remove(screenID)
        saveDisabledScreens()

        guard windowsByScreenID[screenID] == nil else { return }
        let window = makeWallpaperWindow(screen: screen)
        window.load(url(forScreenID: screenID))
        window.orderFrontRegardless()
        windows.append(window)
        windowsByScreenID[screenID] = window
        applyPauseState()
    }

    private func displayText(for url: URL?) -> String {
        guard let url else { return "默认页面" }
        let text = url.absoluteString
        return text.count > 40 ? String(text.prefix(40)) + "…" : text
    }

    // MARK: - 设置网址

    @objc private func promptForDefaultURL() {
        presentURLPrompt(screenID: nil)
    }

    @objc private func promptForScreenURL(_ sender: NSMenuItem) {
        guard let screenID = sender.representedObject as? String else { return }
        presentURLPrompt(screenID: screenID)
    }

    private func presentURLPrompt(screenID: String?) {
        let screen = screenID.flatMap { id in
            NSScreen.screens.first { ScreenIdentity.identifier(for: $0) == id }
        }
        // 菜单打开后屏幕被拔掉，直接忽略
        if screenID != nil && screen == nil { return }

        let current: URL?
        let message: String
        let informative: String
        if let screen, let screenID {
            current = screenURLs[screenID].flatMap { URL(string: $0) }
            message = "设置「\(screen.localizedName)」的网址"
            informative = "仅对该屏幕生效，不填则取消。未单独设置的屏幕会继续使用默认网址。"
        } else {
            current = defaultURL
            message = "设置默认网址"
            informative = "所有未单独设置网址的屏幕都会使用这个网址。"
        }

        NSApp.activate(ignoringOtherApps: true)
        let (alert, field) = makeURLAlert(message: message, informative: informative, initial: current)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let url = Self.normalizedURL(from: input) else {
            showError(message: "无法识别的网址：\(input)", detail: "请检查后重试，例如 https://example.com")
            return
        }

        manualPaused = false
        if let screenID, screen != nil {
            screenURLs[screenID] = url.absoluteString
            saveScreenURLs()
            windowsByScreenID[screenID]?.load(url)
        } else {
            defaultURL = url
            for (id, window) in windowsByScreenID where screenURLs[id] == nil {
                window.load(url)
            }
        }
        applyPauseState()
    }

    @objc private func useDefaultURL(_ sender: NSMenuItem) {
        guard let screenID = sender.representedObject as? String else { return }
        screenURLs.removeValue(forKey: screenID)
        saveScreenURLs()
        manualPaused = false
        windowsByScreenID[screenID]?.load(defaultURL)
        applyPauseState()
    }

    private func makeURLAlert(message: String, informative: String, initial: URL?) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "显示")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = initial?.absoluteString ?? ""
        field.placeholderString = "https://example.com"
        field.isEditable = true
        field.isSelectable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    @objc private func reloadPage() {
        manualPaused = false
        for (screenID, window) in windowsByScreenID {
            window.load(url(forScreenID: screenID))
        }
        applyPauseState()
    }

    @objc private func togglePause() {
        manualPaused.toggle()
        applyPauseState()
    }

    private func showError(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 暂停状态

    private func applyPauseState() {
        let paused = isPaused
        windows.forEach { $0.setPaused(paused) }
    }

    // MARK: - 网页权限

    @objc private func showPermissions() {
        if permissionsWindowController == nil {
            permissionsWindowController = PermissionsWindowController(currentHosts: { [weak self] in
                self?.currentHosts() ?? []
            })
        }
        permissionsWindowController?.reloadAndShow()
    }

    private func currentHosts() -> [String] {
        var hosts: [String] = []
        if let host = defaultURL?.host {
            hosts.append(host)
        }
        for raw in screenURLs.values {
            if let host = URL(string: raw)?.host {
                hosts.append(host)
            }
        }
        return hosts
    }

    /// 把策略解析成最终结果；「每次询问」会弹出原生对话框
    private func resolvePermission(
        _ permission: WebPermission,
        host: String,
        completion: @escaping (Bool) -> Void
    ) {
        switch permissionStore.policy(forSite: host, permission: permission) {
        case .allow:
            completion(true)
        case .deny:
            completion(false)
        case .ask:
            askUser(host: host, permissions: [permission]) { [weak self] allowed, remember in
                guard let self else { return }
                if remember {
                    self.permissionStore.setSitePolicy(allowed ? .allow : .deny, forSite: host, permission: permission)
                }
                completion(allowed)
            }
        }
    }

    private func handleMediaPermission(
        host: String,
        permissions: [WebPermission],
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let policies = permissions.map { permissionStore.policy(forSite: host, permission: $0) }
        if policies.contains(.deny) {
            decisionHandler(.deny)
            return
        }
        if policies.allSatisfy({ $0 == .allow }) {
            grantMedia(decisionHandler)
            return
        }
        askUser(host: host, permissions: permissions) { [weak self] allowed, remember in
            guard let self else { return }
            if remember {
                for permission in permissions {
                    self.permissionStore.setSitePolicy(allowed ? .allow : .deny, forSite: host, permission: permission)
                }
            }
            if allowed {
                self.grantMedia(decisionHandler)
            } else {
                decisionHandler(.deny)
            }
        }
    }

    private func handleMediaCapture(
        origin: WKSecurityOrigin,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = PermissionStore.normalizedSite(origin.host)
        guard !host.isEmpty else {
            decisionHandler(.deny)
            return
        }

        let permissions: [WebPermission]
        switch type {
        case .camera:
            permissions = [.camera]
        case .microphone:
            permissions = [.microphone]
        case .cameraAndMicrophone:
            permissions = [.camera, .microphone]
        @unknown default:
            decisionHandler(.deny)
            return
        }
        handleMediaPermission(host: host, permissions: permissions, decisionHandler: decisionHandler)
    }

    private func grantMedia(_ decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 摄像头/麦克风还需要 macOS 层面的 TCC 授权，把应用带到前台让系统弹窗可见
        NSApp.activate(ignoringOtherApps: true)
        decisionHandler(.grant)
    }

    /// 串行展示授权对话框，避免多个请求同时弹窗
    private func askUser(host: String, permissions: [WebPermission], completion: @escaping (Bool, Bool) -> Void) {
        enqueuePrompt { [weak self] in
            guard let self else { return }
            let controller = PermissionPromptController(host: host, permissions: permissions) { [weak self] allowed, remember in
                guard let self else { return }
                self.activePermissionPrompt = nil
                completion(allowed, remember)
                self.presentNextPrompt()
            }
            self.activePermissionPrompt = controller
            controller.show()
        }
    }

    private func enqueuePrompt(_ block: @escaping () -> Void) {
        promptQueue.append(block)
        presentNextPrompt()
    }

    private func presentNextPrompt() {
        guard activePermissionPrompt == nil, !promptQueue.isEmpty else { return }
        let block = promptQueue.removeFirst()
        block()
    }

    // MARK: - 位置权限桥接

    private func handleGeolocationMessage(_ message: WKScriptMessage) {
        guard let webView = message.webView,
              let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let op = body["op"] as? String else { return }

        let originHost = message.frameInfo.securityOrigin.host
        let host = PermissionStore.normalizedSite(originHost.isEmpty ? (body["host"] as? String ?? "") : originHost)

        if op == "clear" {
            stopLocationWatch(for: webView, id: id)
            return
        }

        guard !host.isEmpty else {
            replyGeolocation(webView, id: id, payload: deniedLocationPayload(watch: op == "watch"))
            return
        }

        resolvePermission(.location, host: host) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.replyGeolocation(webView, id: id, payload: self.deniedLocationPayload(watch: op == "watch"))
                return
            }

            if op == "watch" {
                let token = self.locationService.startWatching { [weak self, weak webView] result in
                    guard let self, let webView else { return }
                    self.replyLocation(result, to: webView, id: id, watch: true)
                }
                if let token {
                    self.locationWatches[ObjectIdentifier(webView), default: [:]][id] = token
                } else {
                    self.replyGeolocation(webView, id: id, payload: self.deniedLocationPayload(watch: true))
                }
            } else {
                self.locationService.requestOneShot { [weak self, weak webView] result in
                    guard let self, let webView else { return }
                    self.replyLocation(result, to: webView, id: id, watch: false)
                }
            }
        }
    }

    private func stopLocationWatch(for webView: WKWebView, id: Int) {
        let key = ObjectIdentifier(webView)
        guard var tokens = locationWatches[key], let token = tokens.removeValue(forKey: id) else { return }
        locationService.stopWatching(token)
        if tokens.isEmpty {
            locationWatches.removeValue(forKey: key)
        } else {
            locationWatches[key] = tokens
        }
    }

    private func clearLocationWatches(for webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let tokens = locationWatches.removeValue(forKey: key) else { return }
        for token in tokens.values {
            locationService.stopWatching(token)
        }
    }

    private func replyLocation(
        _ result: Result<CLLocation, LocationFailure>,
        to webView: WKWebView,
        id: Int,
        watch: Bool
    ) {
        switch result {
        case .success(let location):
            var payload: [String: Any] = [
                "ok": true,
                "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000),
                "coords": [
                    "latitude": location.coordinate.latitude,
                    "longitude": location.coordinate.longitude,
                    "accuracy": location.horizontalAccuracy,
                    "altitude": location.altitude,
                    "altitudeAccuracy": location.verticalAccuracy,
                    "heading": location.course >= 0 ? location.course : -1,
                    "speed": location.speed >= 0 ? location.speed : -1,
                ],
            ]
            if watch { payload["watch"] = true }
            replyGeolocation(webView, id: id, payload: payload)
        case .failure(let failure):
            replyGeolocation(webView, id: id, payload: deniedLocationPayload(watch: watch, code: failure.code, message: failure.message))
        }
    }

    private func deniedLocationPayload(watch: Bool, code: Int = 1, message: String = "User denied Geolocation") -> [String: Any] {
        var payload: [String: Any] = ["ok": false, "code": code, "message": message]
        if watch { payload["watch"] = true }
        return payload
    }

    private func replyGeolocation(_ webView: WKWebView, id: Int, payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.__wwGeoReply && window.__wwGeoReply(\(id), \(json));",
            completionHandler: nil
        )
    }

    // MARK: - 系统事件

    private func registerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    private func bringWindowsToFront() {
        // 系统切换空间或从睡眠唤醒后，重新把壁纸窗口放到桌面层的最前面
        windows.forEach { $0.orderFrontRegardless() }
    }

    @objc private func spaceDidChange() {
        bringWindowsToFront()
    }

    @objc private func handleScreenParametersChange() {
        createWindows()
    }

    @objc private func screensDidSleep() {
        screensAsleep = true
        applyPauseState()
    }

    @objc private func screensDidWake() {
        screensAsleep = false
        applyPauseState()
        bringWindowsToFront()
    }

    @objc private func sessionDidResignActive() {
        sessionInactive = true
        applyPauseState()
    }

    @objc private func sessionDidBecomeActive() {
        sessionInactive = false
        applyPauseState()
    }

    // MARK: - 工具

    static func normalizedURL(from input: String) -> URL? {
        var text = input
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
