import Foundation

/// 网页可以申请、且本应用能够控制的能力。
/// 网页通知（Web Notification / Web Push）不在其中：WKWebView 不支持，设置界面会明确说明。
enum WebPermission: String, CaseIterable {
    case camera
    case microphone
    case location

    var displayName: String {
        switch self {
        case .camera: return "摄像头"
        case .microphone: return "麦克风"
        case .location: return "位置"
        }
    }

    var requestDescription: String {
        switch self {
        case .camera: return "使用摄像头"
        case .microphone: return "使用麦克风"
        case .location: return "获取位置"
        }
    }
}

enum PermissionPolicy: String, CaseIterable {
    case ask
    case allow
    case deny

    var displayName: String {
        switch self {
        case .ask: return "每次询问"
        case .allow: return "允许"
        case .deny: return "拒绝"
        }
    }
}

/// 网页权限的持久化配置：一份全局默认值 + 按站点（域名）覆盖。
final class PermissionStore {

    static let shared = PermissionStore()

    private static let defaultPoliciesKey = "WebWallpaper.defaultPermissions"
    private static let sitePoliciesKey = "WebWallpaper.sitePermissions"

    private(set) var defaultPolicies: [WebPermission: PermissionPolicy] = [:]
    /// 域名 -> 各权限的覆盖值；缺失表示跟随全局默认
    private(set) var sitePolicies: [String: [WebPermission: PermissionPolicy]] = [:]

    private init() {
        load()
    }

    static func normalizedSite(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("://"), let url = URL(string: text), let host = url.host {
            text = host.lowercased()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    func defaultPolicy(for permission: WebPermission) -> PermissionPolicy {
        defaultPolicies[permission] ?? .ask
    }

    func policy(forSite rawSite: String, permission: WebPermission) -> PermissionPolicy {
        let site = Self.normalizedSite(rawSite)
        if let override = sitePolicies[site]?[permission] {
            return override
        }
        return defaultPolicy(for: permission)
    }

    /// 返回该站点是否有显式覆盖（有覆盖时设置界面显示删除按钮）
    func hasOverride(forSite rawSite: String) -> Bool {
        sitePolicies[Self.normalizedSite(rawSite)] != nil
    }

    func setDefaultPolicy(_ policy: PermissionPolicy, for permission: WebPermission) {
        defaultPolicies[permission] = policy
        save()
    }

    /// policy 为 nil 表示「跟随默认」
    func setSitePolicy(_ policy: PermissionPolicy?, forSite rawSite: String, permission: WebPermission) {
        let site = Self.normalizedSite(rawSite)
        guard !site.isEmpty else { return }
        var policies = sitePolicies[site] ?? [:]
        policies[permission] = policy
        if policies.isEmpty {
            sitePolicies.removeValue(forKey: site)
        } else {
            sitePolicies[site] = policies
        }
        save()
    }

    /// 登记一个站点（三个权限都跟随默认），方便用户预先配置
    func addSite(_ rawSite: String) {
        let site = Self.normalizedSite(rawSite)
        guard !site.isEmpty else { return }
        if sitePolicies[site] == nil {
            sitePolicies[site] = [:]
            save()
        }
    }

    func removeSite(_ rawSite: String) {
        sitePolicies.removeValue(forKey: Self.normalizedSite(rawSite))
        save()
    }

    var configuredSites: [String] {
        sitePolicies.keys.sorted()
    }

    // MARK: - 持久化

    private func load() {
        defaultPolicies = [:]
        if let stored = UserDefaults.standard.dictionary(forKey: Self.defaultPoliciesKey) as? [String: String] {
            for (key, value) in stored {
                if let permission = WebPermission(rawValue: key),
                   let policy = PermissionPolicy(rawValue: value) {
                    defaultPolicies[permission] = policy
                }
            }
        }

        sitePolicies = [:]
        if let stored = UserDefaults.standard.dictionary(forKey: Self.sitePoliciesKey) as? [String: [String: String]] {
            for (site, rawPolicies) in stored {
                var policies: [WebPermission: PermissionPolicy] = [:]
                for (key, value) in rawPolicies {
                    if let permission = WebPermission(rawValue: key),
                       let policy = PermissionPolicy(rawValue: value) {
                        policies[permission] = policy
                    }
                }
                sitePolicies[Self.normalizedSite(site)] = policies
            }
        }
    }

    private func save() {
        var defaults: [String: String] = [:]
        for (permission, policy) in defaultPolicies {
            defaults[permission.rawValue] = policy.rawValue
        }
        UserDefaults.standard.set(defaults, forKey: Self.defaultPoliciesKey)

        var sites: [String: [String: String]] = [:]
        for (site, policies) in sitePolicies {
            var raw: [String: String] = [:]
            for (permission, policy) in policies {
                raw[permission.rawValue] = policy.rawValue
            }
            sites[site] = raw
        }
        UserDefaults.standard.set(sites, forKey: Self.sitePoliciesKey)
    }
}
