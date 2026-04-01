---
name: TP_iTerm 90차 감사 — auto-restore/cc-fix/stop-session 버그 패턴
description: 락 파일 레이스, stat fallback 오류, stderr 오염, atomic write 누락 패턴 (2026-04-01)
type: project
---

## 90차 감사 결과 (2026-04-01)

대상 파일: auto-restore.sh, cc-fix.sh, stop-session.sh

### 수정 완료된 버그

| ID | 심각도 | 파일 | 내용 | 수정 방법 |
|----|--------|------|------|----------|
| BUG-STAT-FALLBACK | Warning | auto-restore.sh, cc-fix.sh | `stat -f %m` 실패 시 `echo 0` → LOCK_AGE가 epoch(1.7×10⁹)가 되어 lock 무조건 삭제 | fallback을 `date +%s`(현재시각)으로 교체 → age=0 처리 |
| BUG-LOCK-RACE | Warning | auto-restore.sh, cc-fix.sh | `echo $$ > LOCK_FILE` 직접 쓰기 — 동시 기동 레이스 | `(set -C; echo $$ > LOCK_FILE)` noclobber atomic create로 교체 |
| BUG-STDERR-MIXED | Warning | auto-restore.sh | `2>&1` 혼합 캡처 → python 경고가 GROUPS_JSON에 섞여 tmux 세션명 오염 가능 | stderr를 temp 파일로 분리 후 별도 로깅 |
| BUG-PROTECTED-PIDS-ATOMIC | Warning | auto-restore.sh | stale PID 정리 시 직접 `>` 덮어쓰기 → write 중단 시 파일 손상 | `mktemp` + `mv` atomic write로 교체 |
| BUG-CLEAR-ATOMIC | Warning | stop-session.sh | `--clear` 시 `echo "..." > STOPS_FILE` 직접 쓰기 | python `tempfile.mkstemp` + `os.rename` 패턴으로 교체 |
| BUG-STDERR-IS_VALID | Suggestion | stop-session.sh | `get_valid_windows` 2>&1 → stderr가 stdout에 섞여 grep 입력 오염 | `2>&1` 제거, stderr는 터미널 직출력 |
| BUG-DELAY-COMMENT | Low | auto-restore.sh | 주석 "지수 증가"가 실제 선형 증가 코드와 불일치 | 주석을 실제 동작 설명으로 수정 |

**Why:** atomic write 누락, stat fallback 오류, stderr 혼합은 저빈도지만 발생 시 디버깅 어렵고 데이터 손상 위험.

**How to apply:** 이 패턴들은 다른 스크립트(watchdog.sh, auto-attach.sh 등)에도 동일하게 존재할 가능성이 높음. 다음 감사 시 우선 확인.

### 알려진 미수정 항목

- cc-fix.sh LOCK_HASH: md5 실패 시 모든 세션이 동일 lock 파일 공유 → 실질 위험 낮음(macOS 기본 설치)
