import AppKit
import CoreGraphics
import WebKit

/// 铺满一块屏幕、位于桌面壁纸之上、桌面图标之下的窗口。
/// 默认不接收鼠标事件，不会影响桌面图标的点击和拖拽；
/// 进入浏览模式时临时提升层级并接收鼠标 / 键盘事件。
final class WallpaperWindow: NSPanel {

    let webView: WKWebView
    private let snapshotView = NSImageView()
    private let userContentController: WKUserContentController

    private var currentURL: URL?
    private var showingWelcome = false
    private var showingError = false
    private var isPaused = false
    private var isInteractive = false

    /// 页面开始跳转 / 窗口卸载时通知外部清理该页面的定位订阅
    var onNavigationStarted: (() -> Void)?
    var onUnload: (() -> Void)?
    /// 摄像头 / 麦克风请求交由外部按站点权限决定
    var onMediaCapturePermission: ((WKSecurityOrigin, WKMediaCaptureType, @escaping (WKPermissionDecision) -> Void) -> Void)?

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { isInteractive }

    init(screen: NSScreen, permissionBridge: PermissionBridge) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // 只有带声音的多媒体才需要用户操作，静音视频/动画仍可自动播放
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.preferences.isElementFullscreenEnabled = false

        let controller = WKUserContentController()
        configuration.userContentController = controller

        // 隐藏滚动条，让网页更像壁纸
        let hideScrollbars = WKUserScript(
            source: """
            document.addEventListener('DOMContentLoaded', function () {
                var style = document.createElement('style');
                style.textContent = '::-webkit-scrollbar{display:none!important}html{scrollbar-width:none}';
                document.documentElement.appendChild(style);
            });
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(hideScrollbars)

        // 位置权限交给原生层判断：WebKit 在 macOS 上没有公开的定位授权回调
        controller.addUserScript(
            WKUserScript(
                source: Self.geolocationBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        controller.add(permissionBridge, name: "wwGeolocation")

        userContentController = controller
        webView = WKWebView(frame: screen.frame, configuration: configuration)

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 桌面窗口层之上、桌面图标层之下
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        title = "WebWallpaper"

        let container = NSView(frame: screen.frame)
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .black
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        container.addSubview(webView)

        snapshotView.frame = container.bounds
        snapshotView.autoresizingMask = [.width, .height]
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.isHidden = true
        container.addSubview(snapshotView)

        contentView = container
        setFrame(screen.frame, display: false)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 初始化")
    }

    // MARK: - 位置权限桥接脚本

    /// 拦截 navigator.geolocation，把请求交给原生层判断（按站点策略允许 / 拒绝 / 询问）。
    /// 原生层用 `window.__wwGeoReply(id, payload)` 回传位置或错误。
    private static let geolocationBridgeScript = """
    (function () {
        if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.wwGeolocation) return;
        if (!navigator.geolocation) return;

        var nextId = 1;
        var pending = {};
        var watches = {};

        function makeError(code, message) {
            return {
                code: code,
                message: message,
                PERMISSION_DENIED: 1,
                POSITION_UNAVAILABLE: 2,
                TIMEOUT: 3
            };
        }

        window.__wwGeoReply = function (id, payload) {
            if (payload && payload.watch && watches[id]) {
                var entry = watches[id];
                try {
                    if (payload.ok) {
                        entry.success({ coords: payload.coords, timestamp: payload.timestamp });
                    } else if (entry.error) {
                        entry.error(makeError(payload.code || 2, payload.message || 'Position unavailable'));
                    }
                } catch (e) {}
                return;
            }

            var request = pending[id];
            if (!request) return;
            delete pending[id];
            try {
                if (payload && payload.ok) {
                    if (request.success) request.success({ coords: payload.coords, timestamp: payload.timestamp });
                } else if (request.error) {
                    request.error(makeError((payload && payload.code) || 2, (payload && payload.message) || 'Position unavailable'));
                }
            } catch (e) {}
        };

        function post(payload) {
            window.webkit.messageHandlers.wwGeolocation.postMessage(payload);
        }

        navigator.geolocation.getCurrentPosition = function (success, error, options) {
            var id = nextId++;
            pending[id] = { success: success, error: error };
            post({ id: id, op: 'get', host: location.hostname });
        };

        navigator.geolocation.watchPosition = function (success, error, options) {
            var id = nextId++;
            watches[id] = { success: success, error: error };
            post({ id: id, op: 'watch', host: location.hostname });
            return id;
        };

        navigator.geolocation.clearWatch = function (id) {
            if (!watches[id]) return;
            delete watches[id];
            post({ id: id, op: 'clear', host: location.hostname });
        };

        window.addEventListener('beforeunload', function () {
            Object.keys(watches).forEach(function (id) {
                delete watches[id];
                post({ id: Number(id), op: 'clear', host: location.hostname });
            });
            pending = {};
        });
    })();
    """

    // MARK: - 浏览模式

    /// 切换到可交互的浏览模式：仍在原位置铺满屏幕（不是普通带标题栏的窗口），
    /// 但层级提到普通窗口之上，接收鼠标、滚动、右键与键盘事件。
    func setInteractive(_ interactive: Bool) {
        guard interactive != isInteractive else { return }
        isInteractive = interactive

        if interactive {
            // 去掉 nonactivatingPanel，点击窗口即可激活应用并获得键盘焦点
            styleMask = [.borderless]
            level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
            collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            ignoresMouseEvents = false
            orderFrontRegardless()
            makeKey()
            makeFirstResponder(webView)
        } else {
            styleMask = [.borderless, .nonactivatingPanel]
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
            ignoresMouseEvents = true
            if isKeyWindow {
                resignKey()
            }
            orderFrontRegardless()
        }
    }

    // MARK: - 加载

    func load(_ url: URL?) {
        currentURL = url
        showingWelcome = (url == nil)
        showingError = false
        guard !isPaused else { return }
        snapshotView.isHidden = true
        webView.isHidden = false
        loadPage()
    }

    private func loadPage() {
        showingError = false
        if let currentURL {
            webView.load(URLRequest(url: currentURL))
        } else {
            showingWelcome = true
            webView.loadHTMLString(WelcomePage.html, baseURL: nil)
        }
    }

    // MARK: - 暂停 / 恢复

    /// 暂停时用当前画面截图顶替，并卸载网页，避免动画、视频继续消耗 CPU/电量。
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused

        if paused {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, self.isPaused else { return }
                if let image {
                    self.snapshotView.image = image
                    self.snapshotView.isHidden = false
                }
                self.webView.isHidden = true
                self.webView.stopLoading()
                self.webView.loadHTMLString(
                    "<!doctype html><html><body style=\"margin:0;background:#000\"></body></html>",
                    baseURL: nil
                )
            }
        } else {
            snapshotView.isHidden = true
            webView.isHidden = false
            loadPage()
        }
    }

    // MARK: - 卸载

    /// 关闭窗口前彻底卸载网页，停止加载并释放该屏的 WebContent 资源
    func unload() {
        onUnload?()
        onUnload = nil
        onNavigationStarted = nil
        onMediaCapturePermission = nil
        userContentController.removeScriptMessageHandler(forName: "wwGeolocation")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        snapshotView.image = nil
    }

    // MARK: - 错误处理

    private func presentLoadFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        guard currentURL != nil, !isPaused, !showingError else { return }
        showingError = true
        let html = ErrorPage.html(url: currentURL?.absoluteString ?? "", message: error.localizedDescription)
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - WKNavigationDelegate

extension WallpaperWindow: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 页面跳转后旧的定位订阅已经失效
        onNavigationStarted?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        presentLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        presentLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isPaused else { return }
        loadPage()
    }
}

// MARK: - WKUIDelegate

extension WallpaperWindow: WKUIDelegate {

    /// 摄像头 / 麦克风授权：交给 AppDelegate 按站点策略处理
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let onMediaCapturePermission else {
            decisionHandler(.deny)
            return
        }
        onMediaCapturePermission(origin, type, decisionHandler)
    }

    /// 壁纸不需要弹出新窗口，忽略 window.open / target=_blank，避免被广告页替换
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
