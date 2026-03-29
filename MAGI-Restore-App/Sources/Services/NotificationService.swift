import Foundation

@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    func requestPermission() {}  // 토스트는 권한 불필요

    func notify(title: String, body: String, identifier: String? = nil) {
        ToastService.shared.show(title: title, body: body, icon: "bell.fill")
    }

    func notifySessionCrashed(name: String) {
        ToastService.shared.show(title: "세션 중단", body: "'\(name)' 비정상 종료", icon: "exclamationmark.triangle.fill")
    }

    func notifyRestoreComplete(count: Int) {
        ToastService.shared.show(title: "복원 완료", body: "\(count)개 세션 시작됨", icon: "checkmark.circle.fill")
    }

    func notifySessionStarted(name: String) {
        ToastService.shared.show(title: "세션 시작", body: name, icon: "play.fill")
    }
}
