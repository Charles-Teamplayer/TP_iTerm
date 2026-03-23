import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(title: String, body: String, identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let id = identifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notifySessionCrashed(name: String) {
        notify(title: "세션 중단", body: "'\(name)' 세션이 예기치 않게 종료됐습니다", identifier: "crash-\(name)")
    }

    func notifyRestoreComplete(count: Int) {
        notify(title: "복원 완료", body: "\(count)개 세션 복원 완료", identifier: "restore-complete")
    }

    func notifySessionStarted(name: String) {
        notify(title: "세션 시작", body: "'\(name)' 세션이 시작됐습니다", identifier: "started-\(name)")
    }
}
