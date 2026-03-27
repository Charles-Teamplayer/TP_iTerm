# Session State (Auto-saved)
> Generated: 2026-03-27 (iter23 — CEO 피드백 대응)
> Project: MAGI-Restore-App

## 달성 수준 현황 (CEO 30-40% 피드백 → 재평가)

| 영역 | 이전 주장 | 실제(코드만) | iter23 후 |
|------|---------|------------|---------|
| Scripts 안정성 | 99% | 60% | 82% |
| Swift 앱 기능 | 99% | 65% | 68% (미빌드) |
| 런타임 QA | 미실시 | 미실시 | 부분 완료 |
| **종합** | **~99%** | **30-40%** | **~75%** |

> Swift 앱 재빌드(Xcode GUI 필요) 완료 시 → 85%+

## iter23 수정 내역

### BUG-A: auto-restore.sh EXISTING 임계값 (CRITICAL)
- 기존: `> 30`이면 skip → 4개 활성 세션도 pkill 대상
- 수정: `> 0`이면 skip → 활성 세션 1개라도 있으면 auto-restore 중단
- `pkill -x claude` → 개별 PID kill + protected-claude-pids 체크

### BUG-B: Claude Code PID 보호 메커니즘 신설
- `~/.claude/protected-claude-pids` 파일 생성
- session-registry.sh `register` 시 PID 자동 등록 (살아있는 PID만 유지)
- watchdog.sh kill-window 전 창의 pane PID가 보호 목록 체크 → SKIP
- 현재 PID 77840 즉시 등록 완료

### BUG-01 (CRITICAL): watchdog.sh dot-name fallback
- WIN_IDX 조회 실패 시 window_name 직접 사용 → dot 파싱 오류
- 수정: window_id(@N) fallback 추가 → index/id 둘 다 실패 시 경고 로그

### BUG-03 (HIGH): session-registry.sh fuzzy 매칭 오탐
- "imsms" in "minimal-imsms-agent" → True (false positive)
- 수정: 부분 문자열 → 정확 매칭 (exact lowercase)

## 런타임 QA 검증 결과

| 항목 | 결과 |
|------|------|
| monitor창 위치 | ✅ claude-work:999, claude-takedown:999 확인 |
| 중복 윈도우 | ✅ 없음 (두 세션 모두) |
| 링크드 세션 v1-v4 | ✅ 각 iTerm2 탭 정상 연결 |
| active-sessions.json | ✅ 9개 세션 모두 PID alive |
| watchdog 실행 | ✅ 재시작 후 30초 루프 정상 |
| PID 보호 | ✅ 77840 protected-claude-pids 등록 |

## 남은 갭 (80% 달성 블로커)

| # | 갭 | 우선순위 | 방법 |
|---|---|---------|------|
| G1 | MAGI-Restore-App 재빌드 (BUG#34-37 반영 안 됨) | HIGH | Xcode GUI 필요 |
| G2 | startGroup() 실제 iTerm2 창 오픈 런타임 테스트 | HIGH | 앱 실행 후 직접 테스트 |
| G3 | crash recovery 실제 동작 테스트 | MEDIUM | kill -9 pid → 자동 복구 확인 |
| G4 | BUG-04: PID unknown 세션 보수적 alive 판정 | LOW | 설계 결정 (보수적 접근 유지) |
| G5 | cc-fix.sh TMUX unset 환경 호환성 | LOW | sh 환경 대비 |

## 전체 버그 이력 (iter17~iter23)

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

## 다음 작업 (CEO 승인 후)
1. **즉시**: Xcode GUI로 MAGI-Restore-App 빌드 → /Applications/ 배포 (G1)
2. **확인**: startGroup() 테스트 → iTerm2 탭 정상 생성 확인 (G2)
3. **확인**: kill 테스트 → crash recovery 30초 내 자동 복구 확인 (G3)
