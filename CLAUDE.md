# TP_iTerm 개발 가이드

## TP_skills 연동 (필수)

이 프로젝트의 기술 자산은 `~/claude/TP_skills/projects/50_session_manager.md`에 축적된다.

**세션 시작 시**:
```
~/claude/TP_skills/projects/50_session_manager.md 로드 필수
```

**TP_skills 역반영 의무** — 아래 해당 시 `50_session_manager.md` 즉시 업데이트:
- 버그 수정 → "Ralph Loop 안정화 핵심 지식" 항목 추가
- 반복 발생 이슈 → 재현 조건 + 해결책 기록
- 아키텍처 결정 → 이전 기록 섹션 + 주의사항 반영
- LaunchAgent/Hook 변경 → 연동 시스템 테이블 현행화

## 세션 경계

- `~/claude/TP_iTerm/` 경로만 수정
- 스크립트 변경 동기화 방향: `~/.claude/scripts/` ↔ `TP_iTerm/scripts/` (Source of Truth: `~/.claude/scripts/`)
- `~/claude/TP_skills/`, `~/.claude/` 수정 금지 (skills 세션 담당)

## 프로젝트 개요

> 상세: `~/claude/TP_skills/projects/50_session_manager.md`

macOS Claude Code 세션 자동화. iTerm2 + tmux + LaunchAgent 기반.

- **운영 경로**: `~/claude/TP_iTerm/`
- **스크립트 실행 경로**: `~/.claude/scripts/`
- **smug 설정**: `~/claude/TP_iTerm/smug/claude-work.yml` (동적 생성)
- **activated-sessions**: `~/claude/TP_iTerm/activated-sessions.json` (SPOF — 백업 필수)

## 작업 체크리스트

**시작**: 50_session_manager.md 로드 → "Ralph Loop 안정화 핵심 지식" 확인 → 반복 버그 패턴 숙지
**완료**: 동작 증거 첨부 → 50_session_manager.md 역반영 → ~/.claude/scripts/ 동기화 확인
