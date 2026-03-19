# TP_iTerm

> v2.1 | 2026-03-20 | Ralph Loop 안정화 완료

## 개요

macOS에서 Claude Code 15개 세션(monitor 1 + 프로젝트 14)을 iTerm2 + tmux claude-work로 운영. 재부팅 시 자동 복원, 크래시 30초 감지, 탭 배경색 상태 표시, MAGI-Restore.app 수동 복원.

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
 → auto-restore (LaunchAgent, 즉시)
   → auto-restore.sh 실행 (headless tmux claude-work 생성, intentional-stop 제외)
     → 15개 tmux 윈도우 (monitor + 14 프로젝트)
       → 각 탭: claude --dangerously-skip-permissions --continue

 → auto-attach (LaunchAgent, 동시 시작 → 90초 대기)
   → tmux claude-work 세션 확인
   → iTerm2 실행 대기 (최대 60초)
   → osascript: iTerm2 create window "tmux -CC attach -t claude-work"
   → 탭이 iTerm2 native tmux 탭으로 자동 표시됨

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

### configs/ (설정 파일)
| 파일 | 역할 |
|------|------|
| iterm-config.json | iTerm2 배지/프로젝트명 매핑 설정 (badge, flash, project_names) |
| settings.json | Claude Code 전체 설정 (hooks, permissions) |
| com.claude.*.plist | LaunchAgent plist 원본 (install.sh가 경로 치환 후 설치) |

### iterm2-scripts/AutoLaunch/
| 파일 | 역할 |
|------|------|
| tab_focus_status.py | iTerm2 Python API로 탭 포커스 감지 → 배지 클리어 (tmux -CC 안전) |

### scripts/ (11개)
| 스크립트 | 역할 |
|---------|------|
| auto-restore.sh | 부팅 복원 (headless tmux 세션 생성, intentional-stop 제외) |
| watchdog.sh | 30초 크래시 감지 + 시간 경과 표시 + 배지 설정 |
| tab-focus-monitor.sh | 1초 탭 전환 감지 → 초록 복귀 |
| tab-status.sh | 탭 배경색 + 제목 설정 (7개 상태) + 배지 클리어 연동 |
| session-registry.sh | 세션 레지스트리 (register/unregister/crash-detect/heartbeat) |
| health-check.sh | 전체 시스템 상태 확인 (ps -A 방식, LaunchAgent, scripts, sessions) |
| stop-session.sh | intentional-stop CLI (복원 스킵 등록/제거) |
| agent-count.sh | 활성 에이전트 수 카운트 |
| computer-use-overlay.sh | Computer Use 오버레이 표시 |
| computer-use-start.sh | Computer Use 세션 시작 |
| share-to-imessage.sh | iMessage로 공유 |

### LaunchAgent 데몬 (5개 핵심)
| 데몬 | KeepAlive | 역할 |
|------|:---------:|------|
| com.claude.auto-restore | X (1회) | 부팅 시 tmux 세션 복원 (headless) |
| com.claude.auto-attach | X (1회) | 부팅 후 90초 대기 → iTerm2 tmux -CC attach |
| com.claude.magi-restore | X (1회) | MAGI-Restore.app 자동 실행 |
| com.claude.watchdog | O | 30초 크래시 감지 + 상태 표시 |
| com.claude.tab-focus-monitor | O | 탭 전환 감지 → 초록 복귀 |

### Hook 체계
| 이벤트 | 호출 스크립트 |
|--------|-------------|
| SessionStart | session-start, tp-skills-update, Notion, registry register, tab-status active |
| UserPromptSubmit | tab-status working, registry heartbeat |
| PreToolUse(Bash\|Write\|Edit\|Agent\|Read\|Glob\|Grep) | tab-status working |
| PostToolUse(Write\|Edit) | TP_history 기록, Notion 주기 로그 |
| PostToolUse(Read) | skill-usage-tracker |
| PostToolUse(Bash) | tab-status working |
| Stop | tab-status waiting, Notion |

> Agent 분할은 네이티브 tmux teammate mode로 처리됨 (agent-split.sh/agent-split-close.sh/agent-log.sh 삭제).

## 설치 (다른 Mac)

```bash
git clone https://github.com/Charles-Teamplayer/autoRestart_ClaudeCode.git
cd autoRestart_ClaudeCode

# 방법 1: CLI
bash install.sh

# 방법 2: 앱 더블클릭
open MAGI-Restore.app
```

### install.sh 설치 단계
1. 디렉토리 생성 (`~/.claude/scripts/`, `logs/`, `tab-states/`)
2. scripts/*.sh 복사 + 실행 권한
3. LaunchAgent plist 복사 (경로 자동 치환)
4. tab_focus_status.py → iTerm2 AutoLaunch 설치, iterm-config.json → ~/.claude/config/ 설치
5. iTerm2 tmux integration 설정 (탭 모드, 대시보드 비활성화)
6. LaunchAgent 등록

필수: iTerm2 + `npm install -g @anthropic-ai/claude-code` + PROJECTS 배열 수정

## QA 결과 (2026-03-14, 22개 에이전트 전수조사)

- macOS 호환성: 100% (GNU-only 도구 미사용)
- 탭 색상 플로우: 정상 (초록→노랑→파랑→초록)
- 크래시 감지 체인: 완전 연결 (watchdog→registry→tab-status→auto-restore)
- git repo 동기화: 2026-03-20 Ralph Loop에서 불일치 발견→수정 (tab-status.sh, watchdog.sh 역동기화)
- 로그 로테이션: 전체 구현 완료
- atomic_write: 전체 적용 완료

## Ralph Loop 안정화 (2026-03-20, 20회차 완료)

- health-check.sh: `ps -A` 방식으로 프로세스 감지 수정 (기존 pgrep 오탐 해결)
- tab-status.sh: 배지 클리어 연동, watchdog.sh와 동기화 완료
- watchdog.sh: 배지 설정 로직 추가, iterm-config.json 연동, monitor 창 자동 복구 (iter 16)
- tab_focus_status.py: iTerm2 Python API 네이티브 포커스 감지 (tmux -CC 안전)
- iterm-config.json: 배지/프로젝트명 매핑 중앙 설정
- install.sh: 4단계 추가 (tab_focus_status.py, iterm-config.json 설치)
- Stop hook: intentional-stop 자동 등록 제거 — 명시적 CLI 전용으로 변경 (iter 19)
- session-registry.sh: 알 수 없는 dir → intentional-stop 등록 건너뜀 (iter 18)
- auto-attach.sh: LaunchAgent 추가, 재부팅 후 iTerm2 tmux -CC 자동 연결 (iter 10-12)
