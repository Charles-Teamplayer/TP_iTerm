---
name: project_autorestart
description: autoRestart_ClaudeCode 프로젝트의 핵심 보안 취약점 및 구조적 문제
type: project
---

Claude Code 세션 자동 복구 시스템. iTerm2 + LaunchAgent + smug(tmux) 스택.

**Why:** Claude Code 크래시 시 CEO 수동 개입 없이 자동 재시작이 목표.

**How to apply:** 이 프로젝트 코드 리뷰 또는 수정 시 아래 알려진 취약점을 반드시 참조.

## 알려진 Critical 취약점 (2026-03-14 검증)

1. **session-registry.sh Python heredoc Injection (C-1)**
   - 6개 heredoc 전체에서 $PROJECT_DIR, $PROJECT_NAME 등을 Python 코드에 직접 삽입
   - 수정 방향: 환경변수로 전달하거나 json.dumps()로 직렬화

2. **session-registry.sh PermissionError 미처리 (C-2)**
   - os.kill(pid, 0)의 PermissionError를 catch하지 않아 정상 프로세스를 크래시로 오판

3. **agent-split.sh AppleScript Injection (C-3)**
   - heredoc 내 $PROJECT, $AGENT_LOG 직접 삽입

4. **settings.json skipDangerousModePermissionPrompt: true + 좁은 deny (C-4)**
   - rm -rf ~/claude 등 실질적 위험 명령 허용 상태

## 알려진 Race Condition
- session-registry.sh: 파일 락 없는 JSON R/W (멀티세션 동시 쓰기)
- tab-focus-monitor.sh: /tmp/.iterm2-focus-tty 공유 고정 경로
- watchdog.sh: STATE_FILE 비원자적 쓰기

## 데드코드
- session-registry.sh의 age-check 액션: 구현되어 있으나 아무 곳에서도 호출하지 않음
