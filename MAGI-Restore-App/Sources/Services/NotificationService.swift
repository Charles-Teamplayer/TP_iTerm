import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    // FIX-M (2026-04-27): TP_Sync 스타일 macOS native banner — UNUserNotificationCenter
    // FIX-N (2026-04-28): Toast(in-app) ↔ Native banner 정책 분리
    //   - in-app Toast (ToastService): 사용자 액션 필요 알림 (Open 버튼) — git-sync 로그 열기, attention 탭 포커스
    //   - Native banner (UNUserNotificationCenter): 앱 비활성 시도 보이는 단순 통지 — 복원 완료, 세션 중단
    //   현재 모든 notify*는 둘 다 동시 발송 — 사용자 피로 시 별도 채널화 검토

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliverNative(title: String, body: String, identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil  // 사용자 흐름 방해 최소화 (필요 시 .default 로 변경)
        let req = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func notify(title: String, body: String, identifier: String? = nil) {
        ToastService.shared.show(title: title, body: body, icon: "bell.fill")
        deliverNative(title: title, body: body, identifier: identifier)
    }

    func notifySessionCrashed(name: String) {
        ToastService.shared.show(title: "세션 중단", body: "'\(name)' 비정상 종료", icon: "exclamationmark.triangle.fill")
        deliverNative(title: "⚠️ 세션 중단", body: "'\(name)' 비정상 종료", identifier: "crash-\(name)")
    }

    func notifyRestoreComplete(count: Int) {
        ToastService.shared.show(title: "복원 완료", body: "\(count)개 세션 시작됨", icon: "checkmark.circle.fill")
        deliverNative(title: "✅ 복원 완료", body: "\(count)개 세션 시작됨", identifier: "restore-complete")
    }

    func notifySessionStarted(name: String) {
        ToastService.shared.show(title: "세션 시작", body: name, icon: "play.fill")
        // 개별 시작은 in-app만 (native는 일괄 완료에서 알림)
    }

    func notifyError(title: String, body: String, identifier: String? = nil) {
        ToastService.shared.show(title: title, body: body, icon: "xmark.octagon.fill")
        deliverNative(title: "❌ \(title)", body: body, identifier: identifier)
    }
}
