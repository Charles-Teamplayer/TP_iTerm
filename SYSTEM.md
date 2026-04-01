# TP_iTerm

> v2.6 | 2026-04-01 | Round 96 — 파일 권한 정책 명문화 (반복 권한 이슈 근절)

## 개요

macOS에서 Claude Code 세션을 iTerm2 + tmux 2-group으로 운영. 재부팅 시 자동 복원, 크래시 30초 감지, 탭 배경색 상태 표시, MAGI-Restore.app 수동 복원.

**세션 구성**: claude-work(9창 + monitor) + claude-takedown(7창 + monitor) = 16개 프로젝트 세션

## 탭 색상 체계 (v3)

| 상태 | RGB | 트리거 |
|------|-----|--------|
| active (초록) | 0,220,0 | SessionStart, 탭 클릭 |
| working (노랑) | 255,230,0 | UserPromptSubmit, PreToolUse |
| waiting (파랑) | 0,120,255 | Stop |
| attention (빨강 깜빡임) | 255,80,0 ↔ 255,200,0 | 알림 필요 시 |
| crashed (빨강 깜빡임) | 255,30,30 ↔ 255,150,0 | 크래시 감지 |
| idle_10m/1h/1d/3d | 다단계 | watchdog aging |
| starting (하늘) | 0,180,255 | 부팅 복원 중 |

### 탭 색상 엔진
- 단일 진입점: `~/.claude/tab-color/engine/set-color.sh <state>`
- 설정: `~/.claude/tab-color/config.json` (단일 source of truth)
- 상태 저장: `~/.claude/tab-color/states/{tty}.json`

## 동작 플로우

```
Mac 부팅
 → auto-restore (LaunchAgent, 즉시)
   → auto-restore.sh 실행 (headless tmux 세션 생성, intentional-stop 제외)
     → claude-work(9창) + claude-takedown(7창) + monitor
       → 각 탭: claude --dangerously-skip-permissions --continue

 → auto-attach (LaunchAgent, 동시 시작 → 90초 대기)
   → tmux 세션 확인
   → iTerm2 실행 대기 (최대 60초)
   → osascript: iTerm2 create window "tmux -CC attach -t claude-work"
   → 탭이 iTerm2 native tmux 탭으로 자동 표시됨

세션 중:
 → SessionStart hook → 초록
 → UserPromptSubmit → 노랑
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
| settings.json | Claude Code 전체 설정 (hooks, permissions) |
| claude-work.yml | smug YAML (claude-work 9창 동적 생성) |
| com.claude.*.plist | LaunchAgent plist 원본 (install.sh가 경로 치환 후 설치) |

### iterm2-scripts/AutoLaunch/
| 파일 | 역할 |
|------|------|
| auto_tmux_attach.py | tmux attach + color_sync + focus_monitor (소스 저장소용, 미설치) |
| tab_focus_status.py | FocusMonitor v2 (소스 저장소용, 미설치) |

> iTerm2 AutoLaunch는 비어있음 — tab-focus-monitor.sh (shell LaunchAgent)로 대체됨

### scripts/ (17개)
| 스크립트 | 역할 |
|---------|------|
| auto-restore.sh | 부팅 복원 (headless tmux 세션 생성, 레지스트리 초기화, intentional-stop 제외) |
| auto-attach.sh | 부팅 후 90초 대기 → iTerm2 tmux -CC attach 실행 |
| auto-commit.sh | 자동 git 커밋 (session-manager LaunchAgent에서 호출) |
| watchdog.sh | 30초 크래시 감지 + 시간 경과(aging) 표시 |
| tab-focus-monitor.sh | 1초 탭 전환 감지 → 초록 복귀 |
| tab-status.sh | 탭 배경색 + 제목 설정 → tab-color/engine/set-color.sh 위임 |
| session-registry.sh | 세션 레지스트리 (register/heartbeat/crash-detect) |
| health-check.sh | 전체 시스템 상태 확인 (10개 항목) |
| stop-session.sh | intentional-stop CLI (복원 스킵 등록/제거) |
| cc-fix.sh | tmux CC 클라이언트 없을 때 iTerm2 탭 재생성 |
| agent-count.sh | 활성 에이전트 수 카운트 |
| active-sessions-sync.py | active-sessions orphan 동기화 |
| computer-use-overlay.sh | Computer Use 오버레이 표시 |
| computer-use-start.sh | Computer Use 세션 시작 |
| restore-tab-colors.sh | tab-states 기반 탭 색상 복원 (reattach 후) |
| share-to-imessage.sh | iMessage로 공유 |
| tab-color/ | engine(set-color.sh, flash.sh, restore.sh) + config.json |

### LaunchAgent 데몬 (7개)
| 데몬 | KeepAlive | 역할 |
|------|:---------:|------|
| com.claude.auto-restore | X (1회) | 부팅 시 tmux 세션 복원 (headless) |
| com.claude.auto-attach | X (1회) | 부팅 후 90초 대기 → iTerm2 tmux -CC attach |
| com.claude.magi-restore | X (1회) | MAGI-Restore.app 자동 실행 |
| com.claude.watchdog | O | 30초 크래시 감지 + aging 표시 |
| com.claude.tab-focus-monitor | O | 탭 전환 감지 → 초록 복귀 |
| com.claude.session-manager | X (on-demand) | auto-commit.sh 실행 |
| com.claude.git-auto-sync | X (on-demand) | git-auto-sync (별도 경로 ~/.claude-skills/) |

### Hook 체계
| 이벤트 | 호출 스크립트 |
|--------|-------------|
| SessionStart | cross-impact check, session-start, tp-skills-update, Notion, registry register, tab-status active |
| UserPromptSubmit | tab-status working, registry heartbeat |
| PreToolUse(Bash\|Write\|Edit\|Agent) | tab-status working |
| PreToolUse(Bash) | computer-use 감지 |
| PostToolUse(Write\|Edit) | TP_history 기록, cross-impact record, Notion 주기 로그 |
| PostToolUse(Read) | skill-usage-tracker |
| PostToolUse(Bash) | stale-skills-check |
| Notification | TP_iTerm/hooks/notification.sh (attention 탭 표시) |
| Stop | ralph-report, tab-status waiting, registry intentional-stop, Notion |
| PreCompact | pre-compact-backup, Notion |

## CC 크래시 복구
tmux -CC 연결이 깨지면 터미널에 raw `%extended-output` 라인이 표시됨.

**즉각 복구:**
1. 깨진 터미널에서 `q` 입력 → tmux CC 모드 종료
2. `bash ~/.claude/scripts/cc-fix.sh` 실행 → 자동 재연결

**자동 복구 (watchdog):**
- watchdog이 30초마다 CC 클라이언트 없음 감지 → cc-fix.sh 호출

## 설치 (다른 Mac)

```bash
git clone <repo>
cd TP_iTerm
bash install.sh
```

### install.sh 설치 단계
1. 디렉토리 생성 (`~/.claude/scripts/`, `logs/`, `tab-color/`)
2. scripts/*.sh + scripts/*.py 복사 + 실행 권한
3. tab-color/ 디렉토리 복사
4. LaunchAgent plist 복사 (경로 자동 치환)
5. iTerm2 tmux integration 설정 (탭 모드, 대시보드 비활성화)
6. LaunchAgent 등록

필수: iTerm2 + `npm install -g @anthropic-ai/claude-code`

## 파일 권한 정책

> Round 93~95에서 watchdog.sh 권한이 0755→0600→0755로 반복 변경된 이슈 근절 목적 (Round 96 명문화)

| 대상 | 권한 | 이유 |
|------|:----:|------|
| `scripts/*.sh` | 0755 | 실행 가능해야 함 (LaunchAgent, Hook에서 직접 호출) |
| `scripts/*.py` | 0755 | 실행 가능해야 함 |
| `scripts/tab-color/engine/*.sh` | 0755 | 실행 가능해야 함 |
| `activated-sessions.json` | 0644 | 데이터 파일 (실행 불필요) |
| `configs/*.yml`, `configs/*.json` | 0644 | 설정 파일 (실행 불필요) |
| `configs/*.plist` | 0644 | LaunchAgent 설정 (launchd가 읽기만 함) |

**금지**: 스크립트(.sh, .py)의 실행 권한(+x)을 제거하지 말 것. 제거 시 LaunchAgent/Hook/watchdog 전체 장애 발생.

## QA 결과 (2026-03-31, Ralph Loop iter107~135 전수조사)

- health-check: 10/10 (정상)
- 전수 감사: scripts(17) + hooks(9) + tab-color/engine(3) + LaunchAgent plist(7) + btt(3) + install(1) = 전체 완료
- 수정된 버그: injection 취약(flash.sh/restore.sh/restore-tab-colors.sh), operator precedence(set-color.sh), bash 3.2 비호환(stale-skills-check.sh), grep -cv 패턴(cc-fix.sh), color.log 로테이션 누락
- 삭제된 레거시: scripts/set-color.sh, scripts/auto_tmux_attach.py, configs/iterm-config.json
- 동기화 완료: ~/.claude/scripts/ ↔ TP_iTerm/scripts/ 17개 완전 일치
