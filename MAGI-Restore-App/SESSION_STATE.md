# Session State (Auto-saved at compact)
> Generated: 2026-03-25 01:30 KST
> Project: MAGI-Restore-App

## 현재 상태

### 드래그앤드롭 구현 완료 (미검증)
- **방식**: SwiftUI `.draggable(payload)` + `.dropDestination(for: String.self)`
- **payload 형식**: `"projectName|paneUUID"`
- **드래그 소스**: ContentView의 `sessionRow` HStack에 `.draggable()` 적용
- **드롭 타겟**: 각 pane 헤더, 각 세션 행 (행 드롭 시 순서도 변경)
- **시각 피드백**: hover 시 openHand 커서, 드롭 타겟 위에서 파란 하이라이트

### 창별 중지 기능 추가 완료
- `SessionMonitor.stopGroup(_ group: WindowPane)` 구현
- paneHeader UI에 stop.fill 버튼 추가 (실행 중인 세션이 없으면 비활성화)

### 스크린 상태
- 2026-03-24 00:00 KST 이후 스크린 잠금 중
- 자동화 테스트 불가 (Window Server shield가 모든 CGEvent 차단)
- 사용자가 잠금 해제 후 수동 테스트 필요

### 디버그 로그
- `/tmp/badge_debug.log` — AppStart 이후 이벤트 없음 (스크린 잠금으로 인해)
- 사용자가 드래그 시도 시 `[isTargeted]`, `[drop]`, `[row-drop]` 항목 나타남

### 앱 상태
- PID: 24696 (실행 중)
- 바이너리: `/Applications/TP_iTerm_Restore.app/Contents/MacOS/TP_iTerm_Restore`
- 빌드: 2026-03-25 00:07 KST (최신)

## 다음 단계
1. 사용자가 스크린 잠금 해제 후 앱 창 열기 (메뉴바 아이콘 → "대시보드 열기")
2. 세션 행을 다른 창 헤더로 드래그 테스트
3. 로그 확인: `cat /tmp/badge_debug.log`
4. 동작하면 완료, 안 되면 추가 수정

## 주요 파일
- `Sources/ContentView.swift` — sessionRow (L513), 드래그소스/드롭타겟 (L278-325)
- `Sources/Services/SessionMonitor.swift` — stopGroup (L267)
- `Sources/Services/WindowGroupService.swift` — moveProfile (L45), moveProfileToIndex (L85)
- `Sources/Views/DragDropSupport.swift` — badgeLog만 남음 (NSViewRepresentable 제거됨)
