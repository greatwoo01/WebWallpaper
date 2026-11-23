import AppKit
import CoreLocation
import Foundation

enum LocationFailure: Error {
    /// 用户或系统拒绝
    case denied
    /// 暂时拿不到位置
    case unavailable
    /// 超时
    case timeout

    /// 对应 Web Geolocation API 的错误码
    var code: Int {
        switch self {
        case .denied: return 1
        case .unavailable: return 2
        case .timeout: return 3
        }
    }

    var message: String {
        switch self {
        case .denied: return "User denied Geolocation"
        case .unavailable: return "Position unavailable"
        case .timeout: return "Timeout expired"
        }
    }
}

/// 用 CoreLocation 为网页提供位置信息。
/// 这样不必依赖 WKWebView 的实现，也能按站点决定是否允许。
final class LocationService: NSObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private struct OneShotRequest {
        let completion: (Result<CLLocation, LocationFailure>) -> Void
        let timeout: DispatchWorkItem
    }

    private let manager = CLLocationManager()
    private var oneShotRequests: [OneShotRequest] = []
    private var watchers: [UUID: (Result<CLLocation, LocationFailure>) -> Void] = [:]

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    static var locationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// 单次定位请求；系统授权弹窗、定位失败都会通过 completion 返回
    func requestOneShot(_ completion: @escaping (Result<CLLocation, LocationFailure>) -> Void) {
        guard Self.locationServicesEnabled else {
            completion(.failure(.denied))
            return
        }
        if isDenied(manager.authorizationStatus) {
            completion(.failure(.denied))
            return
        }

        let work = makeTimeout()
        oneShotRequests.append(OneShotRequest(completion: completion, timeout: work))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)

        ensureAuthorization()
        if manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    /// 持续定位；返回 token 用于停止
    func startWatching(_ handler: @escaping (Result<CLLocation, LocationFailure>) -> Void) -> UUID? {
        guard Self.locationServicesEnabled else {
            handler(.failure(.denied))
            return nil
        }
        if isDenied(manager.authorizationStatus) {
            handler(.failure(.denied))
            return nil
        }

        let token = UUID()
        watchers[token] = handler
        ensureAuthorization()
        if manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
        return token
    }

    func stopWatching(_ token: UUID) {
        watchers.removeValue(forKey: token)
        stopIfIdle()
    }

    func stopAllWatching() {
        watchers.removeAll()
        stopIfIdle()
    }

    // MARK: - 内部

    private func isDenied(_ status: CLAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    private func makeTimeout() -> DispatchWorkItem {
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let index = self.oneShotRequests.firstIndex(where: { $0.timeout === work }) else { return }
            let request = self.oneShotRequests.remove(at: index)
            request.completion(.failure(.timeout))
            self.stopIfIdle()
        }
        return work
    }

    /// 系统授权只能在应用位于前台时弹窗
    private func ensureAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.manager.requestWhenInUseAuthorization()
        }
    }

    private func stopIfIdle() {
        guard oneShotRequests.isEmpty, watchers.isEmpty else { return }
        manager.stopUpdatingLocation()
    }

    private func finishOneShots(_ result: Result<CLLocation, LocationFailure>) {
        guard !oneShotRequests.isEmpty else { return }
        let requests = oneShotRequests
        oneShotRequests.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.completion(result)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if !oneShotRequests.isEmpty || !watchers.isEmpty {
                manager.startUpdatingLocation()
            }
        case .denied, .restricted:
            finishOneShots(.failure(.denied))
            let handlers = watchers.values
            watchers.removeAll()
            handlers.forEach { $0(.failure(.denied)) }
            manager.stopUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finishOneShots(.success(location))
        let handlers = watchers.values
        handlers.forEach { $0(.success(location)) }
        stopIfIdle()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let failure: LocationFailure
        if let clError = error as? CLError, clError.code == .denied {
            failure = .denied
        } else {
            failure = .unavailable
        }
        finishOneShots(.failure(failure))
        let handlers = watchers.values
        handlers.forEach { $0(.failure(failure)) }
        stopIfIdle()
    }
}
