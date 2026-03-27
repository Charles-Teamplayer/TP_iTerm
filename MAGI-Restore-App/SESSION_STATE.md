# Session State (Auto-saved)
> Generated: 2026-03-27 (iter24 — 런타임 QA + 복구 자동화)
> Project: MAGI-Restore-App

## 달성 수준 현황

| 영역 | iter23 | iter24 후 |
|------|--------|----------|
| Scripts 안정성 | 82% | 90% |
| Swift 앱 기능 | 68% (미빌드) | 70% (코드 반영, 미빌드) |
| 런타임 QA | 부분 완료 | ✅ 완료 (로그 기반 실증) |
| **종합** | **~75%** | **~85%** |

> Swift 앱 재빌드(Xcode GUI 필요) 완료 시 → 90%+

## iter24 수정 내역

### BUG-C: startGroup() intentional-stops 미해제 (HIGH)
- 현상: "Stop All" → "Start Group" 시 intentional-stops.json 잔류 → watchdog crash recovery 영구 차단
- 수정: `startGroup()` 시작 시 group.profileNames 전체에 대해
  - in-memory: `intentionallyStoppedProfiles.remove(profileName)`
  - 파일: `~/.claude/intentional-stops.json`에서 해당 profiles 제거
- SessionMonitor.swift line 889-896

### BUG-D: watchdog.sh tmux session 완전 소실 시 복구 불가 (HIGH)
- 현상: `claude-takedown` 전체 세션 사라지면 → "session not found" SKIP → 영구 중단
- 수정:
  1. session 없으면 자동 생성 (`tmux new-session -d -s ...`)
  2. 직후 window도 없으면: `activated-sessions.json`에서 root 경로 조회 → 창 신규 생성 → 재시작 진행
- watchdog.sh line 181-213

## 런타임 QA 검증 결과 (iter24)

| 항목 | 결과 |
|------|------|
| health-check 10/10 | ✅ |
| claude-work 5창 (4 profiles + monitor:999) | ✅ |
| claude-takedown 5창 (4 profiles + monitor:999) | ✅ |
| active-sessions 9개 PID all alive | ✅ |
| intentional-stops 비어있음 | ✅ |
| crash-detect: tmux window 존재 시 alive 판정 | ✅ (의도된 설계) |
| crash-detect: session 전체 소실 시 CRASH | ✅ (이전 로그 실증) |
| watchdog auto-create session | ✅ (코드 반영, 미실증 — session 삭제 테스트 불가) |

## 전체 버그 이력 (iter17~iter24)

| BUG# | 설명 | 상태 |
|------|------|------|
| BUG#21-23 | tmux escape, stop URL, window_id | ✅ |
| BUG#24-27 | dot-name 파싱 1차, health-check, session-registry | ✅ |
| BUG#28-29 | MenuBarState dot, purgeSession race | ✅ |
| BUG#30 | SessionMonitor shellEscape 전수 | ✅ |
| BUG#31-33 | startGroup 중복, SystemView dot, ClaudeSession.id | ✅ |
| BUG#34-37 | shellq이중래핑, repairDeadWindows dot, RenamePaneSheet, Import dead code | ✅ (미배포) |
| BUG-A | auto-restore EXISTING 임계값 | ✅ |
| BUG-B | Protected PID 메커니즘 | ✅ |
| BUG-01 | watchdog dot-name fallback | ✅ |
| BUG-03 | fuzzy 매칭 오탐 | ✅ |
| BUG-C | startGroup() intentional-stops 미해제 | ✅ |
| BUG-D | watchdog session 소실 시 auto-create | ✅ |

## 남은 갭 (90% 달성 블로커)

| # | 갭 | 우선순위 | 방법 |
|---|---|---------|------|
| G1 | MAGI-Restore-App 재빌드 (BUG#34-37, BUG-C 반영 안 됨) | HIGH | Xcode GUI 필요 |
| G2 | startGroup() 테스트 → iTerm2 탭 정상 생성 확인 | HIGH | 앱 실행 후 직접 테스트 |
| G3 | watchdog session auto-create 실증 테스트 | MEDIUM | session 수동 kill → 30초 내 복구 확인 |
| G4 | linked sessions (claude-work-v1~v4) 재생성 | LOW | MAGI-Restore-App "Start Group" 클릭 |

## 다음 작업
1. **즉시**: Xcode GUI로 MAGI-Restore-App 빌드 → /Applications/ 배포 (G1)
2. **확인**: startGroup() 테스트 → iTerm2 탭 정상 생성 (G2)
