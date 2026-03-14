#!/bin/bash
# Claude Code Auto-Restore Script
# MAGI+NORN 자동 복원 시스템 - LaunchAgent에서 호출
# tmux + smug + iTerm2 tmux integration

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
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc" 2>/dev/null || true
fi
unset CLAUDECODE

# iTerm2 대기 (최대 60초)
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
    sleep 5
fi

# 이미 claude 프로세스가 다수 실행 중이면 스킵 (수동 실행 상태)
EXISTING=$(ps aux | grep "[c]laude" | grep -v "Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore" | grep -v "??" | wc -l | tr -d ' ')
if [ "$EXISTING" -gt 5 ]; then
    log "이미 claude 프로세스 ${EXISTING}개 실행 중, 스킵"
    exit 0
fi

# 기존 tmux 세션 정리
if tmux has-session -t claude-work 2>/dev/null; then
    log "기존 claude-work tmux 세션 종료"
    tmux kill-session -t claude-work 2>/dev/null || true
    sleep 2
fi

# === Step 1: smug로 tmux 세션 생성 (직접 실행 + has-session polling으로 검증) ===
log "smug start claude-work --detach 직접 실행"
smug start claude-work --detach 2>/dev/null &
SMUG_PID=$!

# tmux 세션이 실제로 생성될 때까지 최대 15초 대기 (0.3초 × 50회)
SMUG_OK=0
for _i in $(seq 1 50); do
    if tmux has-session -t claude-work 2>/dev/null; then
        SMUG_OK=1
        break
    fi
    sleep 0.3
done
wait $SMUG_PID 2>/dev/null

if [ $SMUG_OK -ne 1 ]; then
    log "smug 실패 (15초 내 세션 미생성), tmux 직접 생성 fallback"
    kill $SMUG_PID 2>/dev/null || true

    # Fallback: tmux 직접 세션 생성
    tmux new-session -d -s claude-work -n monitor -c "$HOME/claude" 2>/dev/null

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

    DELAY=0
    for proj in "${PROJECTS[@]}"; do
        NAME=$(echo "$proj" | cut -d: -f1)
        PROJ_PATH=$(echo "$proj" | cut -d: -f2-)
        [ ! -d "$PROJ_PATH" ] && continue
        tmux new-window -t claude-work -n "$NAME" -c "$PROJ_PATH" 2>/dev/null
        tmux send-keys -t "claude-work:$NAME" "sleep $DELAY && unset CLAUDECODE && claude --dangerously-skip-permissions --continue" Enter
        DELAY=$((DELAY + 5))
        log "tmux 윈도우 생성: $NAME"
    done
    log "tmux 직접 생성 완료"
else
    log "smug 성공 (tmux has-session 확인)"
fi

# === Step 2: iTerm2에서 tmux -CC attach (네이티브 탭으로 표시) ===
sleep 3
log "iTerm2에서 tmux -CC attach 실행"
osascript << 'EOF'
tell application "iTerm"
    activate
    delay 1
    set newWindow to (create window with default profile)
    tell newWindow
        tell current session
            write text "tmux -CC attach -t claude-work"
        end tell
    end tell
end tell
EOF
OSASCRIPT_RESULT=$?
if [ $OSASCRIPT_RESULT -ne 0 ]; then
    log "ERROR: iTerm2 attach 실패 (osascript exit $OSASCRIPT_RESULT)"
else
    log "iTerm2 tmux -CC attach 완료"
fi

# 세션 수 확인
sleep 10
SESSION_COUNT=$(tmux list-windows -t claude-work 2>/dev/null | wc -l | tr -d ' ')
log "tmux 윈도우 ${SESSION_COUNT}개 생성됨"

# 복원 완료 macOS 알림
osascript -e "display notification \"Claude Code ${SESSION_COUNT}개 세션 tmux Split View 복원 완료\" with title \"MAGI+NORN\" sound name \"Glass\"" 2>/dev/null || true

# Notion에 복원 기록
if [ -n "$NOTION_API_KEY" ] && [ -f "$HOME/claude/TP_skills/session-manager/notion-advanced.py" ]; then
    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
        "autoRestart_ClaudeCode" "Reboot Recovery (tmux)" "${SESSION_COUNT}개 세션 tmux Split View 복원 완료" 2>/dev/null || true
fi

log "=== Auto-Restore 완료: ${SESSION_COUNT}개 tmux 세션 ==="
