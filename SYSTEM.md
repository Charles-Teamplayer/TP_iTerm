# MAGI+NORN AutoRestart ClaudeCode

> v2.0 | 2026-03-14 | MAGI+NORN 6축 감사 완료

## 개요

macOS에서 Claude Code 14개 세션을 iTerm2 + tmux로 운영. 재부팅 시 자동 복원, 크래시 30초 감지, 탭 배경색 상태 표시, Agent Split View 자동 분할.

## 탭 색상 체계

| 상태 | RGB | 트리거 |
|------|-----|--------|
| active (초록) | 0,220,0 | SessionStart, 탭 클릭 |
| working (노랑) | 255,230,0 | UserPromptSubmit, PreToolUse |
| waiting (파랑) | 0,120,255 | Stop |
| idle (주황) | 255,140,0 | 1시간+ 무입력 |
| stale (어두움) | 80,80,80 | 3일+ 무입력 |
| starting (하늘) | 0,160,255 | 세션 시작/복원 중 |
| crashed (빨강) | 255,0,0 깜빡임 | PID 소멸 감지 |

### 시간 경과 표시 (watchdog 30초 체크)
- 10분+ : 흰색 dot
- 1시간+ : 노랑 dot
- 24시간+ : 빨강 dot
- 3일+ : 빨강/흰 깜빡임

## 동작 플로우

```
Mac 부팅
 → auto-restore (LaunchAgent)
   → iTerm2 대기 → orphan 정리 → smug start claude-work → tmux -CC attach
     → 14개 tmux 윈도우 = iTerm2 네이티브 탭
       → 각 탭: claude --dangerously-skip-permissions --continue

세션 중:
 → SessionStart hook → 초록
 → UserPromptSubmit → 노랑
 → Agent tool → 화면 분할 (Agent Monitor pane)
 → Stop → 파랑
 → 탭 클릭 → 초록 복귀 (focus-monitor 1초 감지)

크래시 시:
 → watchdog 30초 루프 → PID 소멸 감지
   → 탭 빨강 깜빡임 + macOS 알림 + Notion 기록
```

## 컴포넌트

### scripts/ (8개)
| 스크립트 | 역할 |
|---------|------|
| auto-restore.sh | 부팅 복원 (smug + tmux -CC) |
| watchdog.sh | 30초 크래시 감지 + 시간 경과 표시 |
| tab-focus-monitor.sh | 1초 탭 전환 감지 → 초록 복귀 |
| tab-status.sh | 탭 배경색 + 제목 설정 (7개 상태) |
| session-registry.sh | 세션 레지스트리 (register/unregister/crash-detect/heartbeat) |
| agent-split.sh | Agent 실행 시 pane 자동 분할 |
| agent-split-close.sh | Agent 완료 시 pane 닫기 |
| agent-log.sh | Agent 활동 로그 |

### LaunchAgent 데몬 (3개)
| 데몬 | KeepAlive | 역할 |
|------|:---------:|------|
| com.claude.auto-restore | X (1회) | 부팅 시 세션 복원 |
| com.claude.watchdog | O | 크래시 감지 + 상태 표시 |
| com.claude.tab-focus-monitor | O | 탭 전환 감지 |

### Hook 체계
| 이벤트 | 호출 스크립트 |
|--------|-------------|
| SessionStart | session-start, tp-skills-update, Notion, registry register, tab-status active |
| UserPromptSubmit | tab-status working, registry heartbeat |
| PreToolUse(Agent) | agent-log start, agent-split |
| PostToolUse(Agent) | agent-log end, agent-split-close |
| PostToolUse(Write/Edit) | TP_history 기록, Notion 주기 로그 |
| Stop | tab-status waiting, registry unregister, Notion |

## 설치 (다른 Mac)

```bash
git clone https://github.com/Charles-Teamplayer/autoRestart_ClaudeCode.git
cd autoRestart_ClaudeCode

# 방법 1: CLI
bash install.sh

# 방법 2: 앱 더블클릭
open MAGI-Restore.app
```

필수: iTerm2 + `npm install -g @anthropic-ai/claude-code` + PROJECTS 배열 수정

## QA 결과 (2026-03-14, 22개 에이전트 전수조사)

- macOS 호환성: 100% (GNU-only 도구 미사용)
- 탭 색상 플로우: 정상 (초록→노랑→파랑→초록)
- 크래시 감지 체인: 완전 연결 (watchdog→registry→tab-status→auto-restore)
- git repo 동기화: scripts/ = ~/.claude/scripts/ 바이트 일치
- 로그 로테이션: 전체 구현 완료
- atomic_write: 전체 적용 완료
