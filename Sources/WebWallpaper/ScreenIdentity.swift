import AppKit
import CoreGraphics

/// 屏幕的稳定身份标识。
///
/// 显示器在系统中的排列位置、连接顺序都可能变化，`NSScreen` 的索引也不可靠；
/// 这里优先使用显示器 UUID（同一台显示器跨重启、换位都不变），
/// 从而保证每屏网址始终对应到正确的物理屏幕。
enum ScreenIdentity {

    static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(number.uint32Value)
            if let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID) {
                let uuid = uuidRef.takeRetainedValue()
                return CFUUIDCreateString(nil, uuid) as String
            }
        }

        // 极少数虚拟 / 串流显示器拿不到 UUID，退化为「名称 + 分辨率」
        let size = screen.frame.size
        return "name:\(screen.localizedName):\(Int(size.width))x\(Int(size.height))"
    }
}
