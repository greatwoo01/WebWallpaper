import Foundation
import WebKit

/// 把 WKWebView 的脚本消息转发给 AppDelegate。
/// 单独成类便于在多个壁纸窗口间共享，同时避免 WKUserContentController 强引用 AppDelegate。
final class PermissionBridge: NSObject, WKScriptMessageHandler {

    var handler: ((WKScriptMessage) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler?(message)
    }
}
