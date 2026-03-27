# Session State — TP_iTerm iter27
> Generated: 2026-03-27 14:35 KST
> Project: TP_iTerm

## 현재 상태
- Health: 10/10 (정상)
- 활성 세션: claude-work (4창+monitor:999), claude-takedown (4창+monitor:999)
- Claude Code: 8개 모두 정상 (PID 모두 alive)
- watchdog PID: 83530
- MAGI-Restore-App PID: 26541 (13:45 빌드, 모든 iter25 Swift 수정 포함)

## iter27 수정 사항

### BUG-CCFIX-RACE: cc-fix.sh 이중실행 → iTerm2 창 2개 동시 생성
- 로그 증거: `[13:47:35] === cc-fix 시작 ===` 2줄 동시
- 수정: 세션별 PID lock + auto-restore 중 skip + watchdog에서 restore 중 cc-fix 스킵

### BUG-ATTACH-DUP: auto-attach.sh 중복 실행 방지 누락
- 수정: PID 파일 기반 lock

### Stale PIDs 정리
- protected-claude-pids: 9개(88611+8개 dead) → 1개(88611만)

## 누적 수정 목록 (iter26+27)
- BUG-SPACE: watchdog RESTART_PROJECT regex 공백 이름 처리 실패
- BUG-DOT-PANE: tmux pane `.app` 창 이름 오탐
- BUG-LOCK: auto-restore 중복 실행 방지
- BUG-CCFIX-RACE: cc-fix 이중 실행 방지
- BUG-ATTACH-DUP: auto-attach 중복 방지
- BUG-WATCHDOG-RESTORE: auto-restore 중 cc-fix 스킵

## 잔존 갭 (GUI 필요)
- G2: startGroup() iTerm2 탭 생성 (MAGI-Restore-App GUI 클릭 필요)
- G4: linked sessions (claude-work-v0~v3) — 부팅 시 auto-attach로 자동 생성
  현재 없는 이유: 현재 세션이 수동 생성 (auto-restore 미실행)

## 세션 구성
```
claude-work:    0-3 (profiles) + 999:monitor ✅
claude-takedown: 0-3 (profiles) + 999:monitor ✅
```
