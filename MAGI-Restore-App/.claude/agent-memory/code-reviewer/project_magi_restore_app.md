---
name: MAGI-Restore-App 코드 품질 현황
description: MAGI-Restore-App SwiftUI 앱의 버그/크래시 위험/로직 오류 전수 검토 결과 (2026-03-24)
type: project
---

2026-03-24 전수 코드 검토 수행. Sources/ 디렉토리 9개 Swift 파일 대상.

**Why:** CEO 요청으로 버그, 크래시 가능성, 로직 오류, 미완성 기능 전수 점검 수행.

**How to apply:** 향후 리뷰 시 아래 이슈들이 수정되었는지 확인. 특히 ShellService.run()의 process.run() 실패 무시, ActivationService race condition, ProfileService.parseYml()의 force unwrap이 핵심 수정 대상.

주요 발견 이슈:
- CRITICAL: ShellService.run() — process.run() 실패를 try?로 묵살, 프로세스 미실행 시 빈 문자열 반환 (오판 위험)
- HIGH: ActivationService — @MainActor 없이 여러 스레드에서 파일 R/W race condition 가능
- HIGH: ProfileService.parseYml() — currentRoot! force unwrap (L68)
- HIGH: ProfileService.generateYml() — 프로필명에 특수문자 포함 시 YAML 깨짐 (따옴표 처리 없음)
- MEDIUM: SessionMonitor.restoreSelected() — isRefreshing=true를 직접 set하여 외부 refresh() 차단 (defer 로직 꼬임)
- MEDIUM: SystemView.toggle() — @MainActor 함수 내에서 Task{} 로 비동기 실행, daemon.isRunning 상태 inconsistency
- MEDIUM: repairDeadWindows() — pipe(|) 포함 경로 처리 시 parts.count==2 검사만으로는 불충분
- LOW: ShellService — 하드코딩 fallback 경로 v22.18.0 (L21)
- LOW: SessionsView — 완전삭제(showPurgeConfirm) confirmationDialog가 실행 중/중단 양쪽 버튼에서 공유, 상태 꼬임 가능
