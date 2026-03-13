#!/bin/bash
# Claude Code Auto-Restore Script
# MAGI+NORN 자동 복원 시스템 - LaunchAgent에서 호출
# tmux 미사용 — iTerm2 AppleScript로 직접 탭 생성

LOG_FILE="$HOME/.claude/logs/auto-restore.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Auto-Restore 시작 ==="

# 부팅 시 orphan tab-states 정리 (이전 세션 잔존 파일 제거)
STATE_DIR="$HOME/.claude/tab-states"
if [ -d "$STATE_DIR" ]; then
    for sf in "$STATE_DIR"/ttys*; do
        [ ! -f "$sf" ] && continue
        TTY_DEV="/dev/$(basename "$sf")"
        if [ ! -c "$TTY_DEV" ]; then
            rm -f "$sf"
            log "Orphan tab-state 제거: $(basename "$sf")"
        fi
    done
fi

# 환경변수 로드 후 CLAUDECODE 해제 (순서 중요: source 후 unset)
if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc" 2>/dev/null || true
fi
unset CLAUDECODE

# 프로젝트 목록 (이름:경로)
PROJECTS=(
    "imsms:$HOME/claude/TP_newIMSMS"
    "imsms-agent:$HOME/claude/TP_newIMSMS_Agent"
    "mdm:$HOME/claude/TP_MDM"
    "tesla-lvds:$HOME/claude/TP_TESLA_LVDS"
    "tesla-dashboard:$HOME/ralph-claude-code/TESLA_Status_Dashboard"
    "mindmap:$HOME/claude/TP_MindMap_AutoCC"
    "sj-mindmap:$HOME/SJ_MindMap"
    "imessage:$HOME/claude/TP_A.iMessage_standalone_01067051080"
    "btt:$HOME/claude/TP_BTT"
    "infra:$HOME/claude/TP_Infra_reduce_Project"
    "skills:$HOME/claude/TP_skills"
    "appletv:$HOME/claude/AppleTV_ScreenSaver.app"
    "imsms-web:$HOME/claude/imsms.im-website"
    "auto-restart:$HOME/claude/autoRestart_ClaudeCode"
)

# iTerm2 polling 대기 (최대 60초)
MAX_WAIT=60
WAITED=0
if ! pgrep -x "iTerm2" > /dev/null; then
    log "iTerm2 시작 대기 중..."
    open -a iTerm || { log "ERROR: iTerm2 미설치 또는 실행 실패"; exit 1; }
    while ! pgrep -x "iTerm2" > /dev/null && [ $WAITED -lt $MAX_WAIT ]; do
        sleep 2
        WAITED=$((WAITED + 2))
    done
    if [ $WAITED -ge $MAX_WAIT ]; then
        log "ERROR: iTerm2 시작 타임아웃 (${MAX_WAIT}초)"
        exit 1
    fi
    log "iTerm2 시작됨 (${WAITED}초 대기)"
    sleep 5  # iTerm2 UI 완전 안정화 대기
fi

# 이미 claude 프로세스가 다수 실행 중이면 스킵 (수동 실행 상태)
EXISTING=$(ps aux | grep "[c]laude" | grep -v "Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore" | grep -v "??" | wc -l | tr -d ' ')
if [ "$EXISTING" -gt 5 ]; then
    log "이미 claude 프로세스 ${EXISTING}개 실행 중, 스킵"
    exit 0
fi

# iTerm2 AppleScript로 탭 생성
log "iTerm2 탭 생성 시작 (${#PROJECTS[@]}개 프로젝트)"

# 첫 번째 프로젝트: 새 윈도우 생성
FIRST_NAME=$(echo "${PROJECTS[0]}" | cut -d: -f1)
FIRST_PATH=$(echo "${PROJECTS[0]}" | cut -d: -f2-)

if [ ! -d "$FIRST_PATH" ]; then
    log "ERROR: 첫 번째 프로젝트 디렉토리 없음: $FIRST_PATH"
    exit 1
fi

osascript << EOF
tell application "iTerm"
    activate
    set newWindow to (create window with default profile)
    tell newWindow
        set theSession to current session
        tell theSession
            set name to "${FIRST_NAME}"
            write text "unset CLAUDECODE && cd ${FIRST_PATH} && bash ~/.claude/scripts/tab-status.sh starting ${FIRST_NAME} && claude --dangerously-skip-permissions --continue"
        end tell
    end tell
end tell
EOF

if [ $? -ne 0 ]; then
    log "ERROR: iTerm2 첫 번째 윈도우 생성 실패"
    exit 1
fi
log "탭 생성: ${FIRST_NAME}"

# 나머지 프로젝트: 탭 추가 (5초 간격)
for i in $(seq 1 $((${#PROJECTS[@]} - 1))); do
    sleep 5
    NAME=$(echo "${PROJECTS[$i]}" | cut -d: -f1)
    PROJ_PATH=$(echo "${PROJECTS[$i]}" | cut -d: -f2-)

    # 디렉토리 존재 확인
    if [ ! -d "$PROJ_PATH" ]; then
        log "WARNING: 디렉토리 없음, 스킵: $PROJ_PATH"
        continue
    fi

    osascript << EOF
tell application "iTerm"
    tell current window
        set newTab to (create tab with default profile)
        tell newTab
            set theSession to (current session of newTab)
            tell theSession
                set name to "${NAME}"
                write text "unset CLAUDECODE && cd ${PROJ_PATH} && bash ~/.claude/scripts/tab-status.sh starting ${NAME} && claude --dangerously-skip-permissions --continue"
            end tell
        end tell
    end tell
end tell
EOF
    log "탭 생성: ${NAME}"
done

SESSION_COUNT=${#PROJECTS[@]}

# 복원 완료 macOS 알림
osascript -e "display notification \"Claude Code ${SESSION_COUNT}개 세션 복원 완료\" with title \"MAGI+NORN\" sound name \"Glass\"" 2>/dev/null || true

# Notion에 복원 기록
if [ -n "$NOTION_API_KEY" ] && [ -f "$HOME/claude/TP_skills/session-manager/notion-advanced.py" ]; then
    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
        "autoRestart_ClaudeCode" "Reboot Recovery" "${SESSION_COUNT}개 세션 자동 복원 완료" 2>/dev/null || true
fi

log "=== Auto-Restore 완료: ${SESSION_COUNT}개 세션 ==="
