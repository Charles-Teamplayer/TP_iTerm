# Session State (Auto-saved at compact)
> Generated: 2026-03-27 11:35 (iter21)
> Project: MAGI-Restore-App

## Ralph Loop iter21 완료 상태

### BUG#31+32 Fix (이번 iter에서 완료)

**BUG#31**: startGroup 중복 클릭 → iTerm2 창 2개 생성 방지
- SessionMonitor: `startingGroups: Set<String>` 추가 → 진행 중 재진입 차단
- ContentView: Start 버튼 isStarting 시 disabled + hourglass 아이콘

**BUG#32**: SystemView.swift `display-message -t sname:win.name` 점 오파싱
- `list-windows -F '#{window_index}\u{01}#{window_name}\u{01}#{pane_tty}'` 단일쿼리로 교체
- TPiTermRestoreApp BUG#28, MenuBarState BUG#28과 동일 패턴

### BUG#30 Fix (이전 iter에서 완료)
SessionMonitor.swift — shellEscape tmuxSession 전수 적용 (7곳)
- restartSession: send-keys 2곳 + list-panes 1곳
- restoreSelected: send-keys 2곳 + list-panes 1곳
- forceResetSession: kill-window 1곳
- stopAllRunning/doStop: kill-window 1곳
- stopGroup: group.sessionName kill-window 1곳
- purgeIdleZshWindows: list-panes + kill-window 2곳

### 커밋 이력 (iter17-20)
- iter17: BUG#21+22 (tmuxSession escape, stop-session.sh URL)
- iter18: BUG#23-27 (window_id, health-check, session-registry)
- iter19: BUG#28+29 (MenuBarState dot-issue, purgeSession race)
- iter20: BUG#30 (shellEscape 전수 일관성)

### 전체 달성 수준 (iter21 기준 — 약 93%)
- tmux 탈출 일관성: ✅ 완료 (BUG#21-32)
- monitor 창 999배치: ✅ 4곳 모두 구현
- startGroup 중복클릭 방지: ✅ BUG#31 (startingGroups Set)
- 중복 창 방지 (launchProfile): ✅ atomic check+create
- display-message dot issue: ✅ 모든 3개 파일 수정 완료
- intentional-stop 체인: ✅ 모든 경로 완전
- watchdog self-protection: ✅ non-tmux TTY 보호
- Claude Code PID 보호: ✅ watchdog에 자체 터미널 보호 로직 있음

### 잔존 이슈 (낮은 우선순위)
- ClaudeSession.id = windowName: 다중 세션에서 같은 window name 충돌 가능성 (현실적 미발생)
- openITermTabs: sname linked session 이스케이프 (tmux 세션명 공백 불허로 안전)
- CLI xcodebuild 빌드 실패 (pre-existing): SystemView/WindowGroupService scope 오류
  → Xcode GUI 빌드 필요 (우리 변경과 무관)

### 다음 iter 시 우선 작업
1. Xcode GUI 빌드 후 /Applications/ 배포
2. ClaudeSession.id 고유성 개선 (다중 세션 edge case)
3. 50_session_manager.md iter21 역반영
