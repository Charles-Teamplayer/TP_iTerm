# Session State — TP_iTerm iter26
> Generated: 2026-03-27 14:15 KST
> Project: TP_iTerm

## 현재 상태
- Health: 10/10 (정상)
- 활성 세션: claude-work (4창+monitor:999), claude-takedown (4창+monitor:999)
- Claude Code: 8개 모두 정상 (PID 모두 alive)
- watchdog PID: 60149 (2026-03-27 14:13 재시작)
- MAGI-Restore-App PID: 26541

## iter26 수정 사항

### BUG-SPACE: RESTART_PROJECT regex 공백 이름 처리 실패
- **파일**: `watchdog.sh` line 114
- **증상**: `ims_Auto_Contact APP` → regex `[^ ]*` → `ims_Auto_Contact`만 추출 → activated-sessions path 못 찾음 → SKIP restart
- **수정**: `sed -n 's/.*CRASH DETECTED: \(.*\) (PID:.*/\1/p'` — `(PID:` 앞까지 전체 캡처
- **영향**: 공백 포함 프로젝트명 crash recover 불가 버그 해결

### BUG-DOT-PANE: tmux pane 참조 시 `.` 포함 창 이름 오탐
- **파일**: `watchdog.sh` line 214
- **증상**: `AppleTV_ScreenSaver.app` → `tmux list-panes -t "claude-work:AppleTV_ScreenSaver.app"` → tmux가 `.app`를 pane 구분자로 해석 → "can't find pane: app" stderr
- **수정**: 보호 PID 체크 시 먼저 window_id(@N) 조회 후 `tmux list-panes -t "$WIN_ID"` 사용
- **영향**: `.` 포함 창 이름 모두 안전하게 처리

### auto-restore 중복 실행 방지 lock
- **파일**: `auto-restore.sh`
- **증상**: LaunchAgent + auto-attach.sh 동시 트리거 시 두 auto-restore가 동시 실행 → 두 번째 실행이 첫 번째가 만든 세션을 destroy
- **수정**: PID 파일 기반 lock (`/tmp/.auto-restore.lock`) — flock은 macOS 없음
- **영향**: 동시 auto-restore 실행 방지

## 잔존 갭 (미해결)
- G2: startGroup() iTerm2 탭 실제 생성 테스트 (GUI 클릭 필요)
- G4: linked sessions (claude-work-v1~v4) 미생성 → MAGI-Restore-App Start Group 필요
- MAGI-Restore-App 빌드 배포 검증 필요 (PID 26541 실행 중)

## 세션 구성
```
claude-work:
  0:teamplean-website (PID 23236 / ttys000)
  1:universalMAC_Converter_gensys_calude (PID 23299 / ttys001)
  2:ims_Auto_Contact APP (PID 23772 / ttys004)
  3:AppleTV_ScreenSaver.app (PID 23970 / ttys005)
  999:monitor

claude-takedown:
  0:terminal-mirror (PID 24633 / ttys007)
  1:TP_skills (PID 24976 / ttys009)
  2:TP_MDM (PID 25530 / ttys010)
  3:TP_MindMap_AutoCC (PID 25890 / ttys011)
  999:monitor
```
