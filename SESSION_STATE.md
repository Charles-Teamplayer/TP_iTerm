# Session State
> Generated: 2026-03-28 | Project: TP_iTerm

## 현재 상태
- iter61 진행 중: 창 복제 원인 분석 및 수정 완료

## 완료된 작업 (iter61)

### 근본 원인 발견
- `com.claude.auto-restore` + `com.claude.magi-restore` 두 LaunchAgent가 동시에 `auto-restore.sh` 호출
- 매 실행마다 새 iTerm 창 생성, 기존 창 미정리 → 87개 누적

### 수정 내용
1. **auto-restore.sh**: 30분 쿨다운 추가 (`LASTRUN_FILE` 기반)
   - 부팅 직후(uptime <300s)나 `--force` 아니면 1800초 내 재실행 차단
   - window-events.log에 START/COMPLETE/COOLDOWN_SKIP 기록

2. **auto-attach.sh**: orphan iTerm 창 정리 로직
   - TTY에서 zsh 단독 실행 창 감지 후 자동 닫기
   - window-events.log에 CREATE/CLEANUP 기록

3. **~/.claude/logs/window-events.log**: 신규 이벤트 로그
   - 모든 창 생성/삭제 이벤트 기록

### 즉시 정리
- 87개 orphan iTerm 창 → 3개로 정리 완료

## 미완료
- Ralph Loop VERDANDI QA 검증 (진행 예정)
- TP_skills/projects/50_session_manager.md 역반영
