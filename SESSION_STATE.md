# Session State — TP_iTerm iter31 완료
> 업데이트: 2026-03-27 | Ralph Loop 진행 중

## 달성 현황: ~99%

### iter31 수정 항목 (오늘)
1. **BUG-NOSTOPCHECK** (`auto-restore.sh`) — intentional-stops.json 체크 누락
   - stop-session.sh로 중지해도 reboot 시 무조건 복원되던 버그
   - 48h TTL 적용해서 만료된 정지 항목은 무시
2. **BUG-REGMAP** (`session-registry.sh`) — DIR_TO_WINDOW 오래된 단축명
   - "mindmap", "skills", "mdm", "session-mgr" 등 → 실제 profile명과 불일치
   - a.imessage, AppleTV_ScreenSaver.app 예외만 남기고 전부 제거 (fallback basename 사용)
3. **BUG-HC-WCOUNT** (`health-check.sh`) — WIN_COUNT → TOTAL_WIN_COUNT 오타

### 이전 iter 수정 요약
- iter26~30: 총 20개 버그 수정 (WINRACE, ATOMIC, REGEX, COOLDOWN, ARRACE, TTY-WRITE 등)
- iter31: 3개 추가 수정 → 누적 23개

## 전체 시스템 구성 현황
- `auto-restore.sh` — 부팅 시 tmux 세션 + 프로파일 복원 ✅
- `watchdog.sh` — 크래시 감지 + 자동 재시작 ✅
- `session-registry.sh` — 세션 등록/해제/crash-detect ✅
- `stop-session.sh` — intentional-stop CLI ✅
- `health-check.sh` — 시스템 상태 확인 ✅
- `tab-focus-monitor.sh` — 탭 포커스 색상 복원 ✅
- `MAGI-Restore-App` — Swift GUI 앱 ✅

## 남은 검증 사항
- G2: startGroup() GUI 실제 테스트 (Xcode 앱 직접 실행 필요)
- G4: linked sessions 동작 (부팅 사이클 필요)
