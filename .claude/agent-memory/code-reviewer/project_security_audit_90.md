---
name: TP_iTerm 보안 전수 감사 (90차, 2026-04-01)
description: QA-Security 역할로 전체 스크립트/Swift 코드 보안 스캔 결과 — 5개 취약점 발견 및 4개 수정
type: project
---

## 감사 결과 요약 (2026-04-01)

전체 스캔 범위: 쉘 스크립트 19개 + Python 3개 + Swift 16개

**Why:** 90차 정기 전수 감사 — QA-Security 역할 단독 수행

**How to apply:** 다음 세션에서 동일 파일 수정 시 SEC-001~005 수정 이력 참조

---

## 발견 취약점

### CRITICAL (수정 완료)

**SEC-001** — `SessionMonitor.swift` `launchProfile`(라인 862) + `createSession`(라인 1340)
- `tmux send-keys` 인수가 다른 함수와 달리 더블쿼트로 래핑 → $(), 백틱 확장 위험
- **수정**: 싱글쿼트 래핑 + `'\\''` 이스케이프로 변경 (restoreSession/checkAutoSync 패턴과 일관화)
- 영향 파일: `MAGI-Restore-App/Sources/Services/SessionMonitor.swift`

### WARNING (수정 완료)

**SEC-002** — `watchdog.sh:115`, `auto-attach.sh:24`
- PID lock 파일 쓰기가 TOCTOU race condition (set -C noclobber 미사용)
- **수정**: `(set -C; echo $$)` 패턴으로 원자적 락 구현 (auto-restore.sh 패턴과 일관화)

**SEC-003** — `tab-color/engine/set-color.sh:181-182`
- osascript `-e` 알림에서 `_SAFE_PROJECT`가 개행·백틱·`$()` 미제거
- **수정**: `tr -d '\n\r\`$'` 추가, 이모지 포함 subtitle 제거

**SEC-004** — `watchdog.sh:59-60`
- `/tmp/watchdog-latest-event.txt` 권한 `rw-r--r--` → PID 목록 등 민감 정보 노출
- **수정**: 생성 직후 `chmod 0600` 적용

### SUGGESTION (주석 처리)

**SEC-005** — `auto-attach.sh:117-118`
- OSEOF2 heredoc 비인용 + `_ORPHAN_LIST` 직접 삽입
- TTY 경로만 포함하므로 실질 위험 낮음, awk 패턴에 alphanumeric 필터 추가로 완화

---

## 클린 확인 항목

- 하드코딩 시크릿: 없음 (API 키, 토큰, 비밀번호 없음)
- eval 사용: 없음 ($(cat) 패턴은 파일 읽기 전용으로 안전)
- chmod 777 / world-writable 파일: 없음
- Python shell=True / os.system: 없음
- pickle/marshal: 없음
- /tmp symlink: mktemp 사용 확인 (share-to-imessage.sh 이미 적용)
- 직접 실행 변수 (`exec $VAR`, `bash $VAR`): 없음 (install.sh echo만 해당)
