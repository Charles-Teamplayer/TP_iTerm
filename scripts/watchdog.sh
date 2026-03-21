#!/bin/bash
# Claude Code Watchdog (VERDANDI-5 검증 + 민수 구현)
# LaunchAgent KeepAlive로 보호됨

LOG_FILE="$HOME/.claude/logs/watchdog.log"
REGISTRY="$HOME/.claude/active-sessions.json"
RESTART_COOLDOWN=60  # 같은 프로젝트 재시작 간 최소 대기시간(초)
RESTART_LOG="$HOME/.claude/logs/restart-history.log"
CRASH_COUNT_DIR="/tmp/.claude-crash-counts"  # 연속 크래시 카운터 (재부팅 시 초기화)
CRASH_MAX=5  # 이 횟수 초과 시 intentional-stop 등록
mkdir -p "$CRASH_COUNT_DIR"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    # 로그 로테이션 (50000줄 초과 시)
    if [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 50000 ] 2>/dev/null; then
        tail -25000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
    fi
}

# 디스크 여유 공간 체크 (MB)
disk_free_mb() {
    df -k "$HOME" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

# 원자적 파일 쓰기 (디스크 부족 시 스킵)
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.$$"
    local free_mb
    free_mb=$(disk_free_mb)
    if [ "${free_mb:-0}" -lt 200 ]; then
        return 0  # 디스크 부족 시 조용히 스킵
    fi
    echo "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null
}

# stderr.log 자체 로테이션 (10MB 초과 시)
rotate_stderr_log() {
    local stderr_log="$HOME/.claude/logs/watchdog.stderr.log"
    if [ -f "$stderr_log" ]; then
        local size
        size=$(stat -f%z "$stderr_log" 2>/dev/null || echo 0)
        if [ "${size:-0}" -gt 10485760 ]; then  # 10MB
            > "$stderr_log"
        fi
    fi
}

notify() {
    osascript -e "display notification \"$1\" with title \"MAGI+NORN Watchdog\" sound name \"Basso\"" 2>/dev/null || true
}

# 환경변수 로드
if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc" 2>/dev/null || true
fi
unset CLAUDECODE

log "=== Watchdog 시작 ==="

# Watchdog 재시작 시 crash-count 초기화 (오래된 카운터로 인한 조기 intentional-stop 방지)
rm -rf "${CRASH_COUNT_DIR:?}"/*  2>/dev/null || true
log "Crash-count 초기화 완료"

# 메인 루프
while true; do
    # 1. 레지스트리 기반 크래시 감지
    if [ -f "$REGISTRY" ]; then
        CRASHED=$(bash "$HOME/.claude/scripts/session-registry.sh" crash-detect 2>/dev/null | grep "CRASH DETECTED" || true)

        if [ -n "$CRASHED" ]; then
            log "CRASH DETECTED: $CRASHED"
            notify "Claude Code 크래시 감지! 자동 재시작 중..."

            # Notion에 크래시 기록
            if [ -n "$NOTION_API_KEY" ]; then
                # 크래시된 각 프로젝트에 대해 기록
                echo "$CRASHED" | while IFS= read -r line; do
                    PROJECT=$(echo "$line" | sed -n 's/.*CRASH DETECTED: \([^ ]*\).*/\1/p')
                    PROJECT="${PROJECT:-unknown}"
                    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
                        "$PROJECT" "Crash Recovery" "프로세스 비정상 종료 감지 - 자동 재시작" 2>/dev/null || true
                done
            fi

            # 크래시된 세션의 탭에 ⚪🔴 깜빡임 표시
            echo "$CRASHED" | while IFS= read -r line; do
                CRASH_PROJECT=$(echo "$line" | sed -n 's/.*CRASH DETECTED: \([^ ]*\).*/\1/p')
                CRASH_PROJECT="${CRASH_PROJECT:-unknown}"
                CRASH_TTY=$(echo "$line" | sed -n 's/.*TTY: \([^ ,]*\).*/\1/p')
                # TAB_TTY 주입으로 LaunchAgent 컨텍스트에서도 정확한 TTY에 색상 씀
                if [ -n "$CRASH_TTY" ]; then
                    TAB_TTY="/dev/${CRASH_TTY}" bash "$HOME/.claude/scripts/tab-status.sh" crashed "$CRASH_PROJECT" &
                else
                    bash "$HOME/.claude/scripts/tab-status.sh" crashed "$CRASH_PROJECT" &
                fi
            done

            # 크래시된 세션 자동 재시작 (P0 수정: watchdog이 직접 복구)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $CRASHED" >> "$RESTART_LOG"

            echo "$CRASHED" | while IFS= read -r line; do
                RESTART_PROJECT=$(echo "$line" | sed -n 's/.*CRASH DETECTED: \([^ ]*\).*/\1/p')
                [ -z "$RESTART_PROJECT" ] && continue

                # cooldown 체크 (같은 프로젝트 60초 내 재시작 방지)
                LAST_RESTART=$(grep "$RESTART_PROJECT" "$RESTART_LOG" 2>/dev/null | tail -2 | head -1 | sed 's/\[//' | sed 's/\].*//')
                if [ -n "$LAST_RESTART" ]; then
                    LAST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LAST_RESTART" +%s 2>/dev/null || echo 0)
                    NOW_EPOCH=$(date +%s)
                    if [ $((NOW_EPOCH - LAST_EPOCH)) -lt $RESTART_COOLDOWN ]; then
                        log "SKIP restart $RESTART_PROJECT (cooldown ${RESTART_COOLDOWN}s)"
                        continue
                    fi
                fi

                # 프로젝트명 → tmux 윈도우명 + 경로 매핑
                WINDOW_NAME=""
                PROJ_PATH=""
                case "$RESTART_PROJECT" in
                    TP_newIMSMS)           WINDOW_NAME="imsms";           PROJ_PATH="$HOME/claude/TP_newIMSMS" ;;
                    TP_newIMSMS_Agent)     WINDOW_NAME="imsms-agent";     PROJ_PATH="$HOME/claude/TP_newIMSMS_Agent" ;;
                    TP_MDM)               WINDOW_NAME="mdm";             PROJ_PATH="$HOME/claude/TP_MDM" ;;
                    TP_TESLA_LVDS)        WINDOW_NAME="tesla-lvds";      PROJ_PATH="$HOME/claude/TP_TESLA_LVDS" ;;
                    TESLA_Status_Dashboard) WINDOW_NAME="tesla-dashboard"; PROJ_PATH="$HOME/ralph-claude-code/TESLA_Status_Dashboard" ;;
                    TP_MindMap_AutoCC)    WINDOW_NAME="mindmap";         PROJ_PATH="$HOME/claude/TP_MindMap_AutoCC" ;;
                    SJ_MindMap)           WINDOW_NAME="sj-mindmap";      PROJ_PATH="$HOME/SJ_MindMap" ;;
                    TP_A.iMessage_standalone_01067051080) WINDOW_NAME="imessage"; PROJ_PATH="$HOME/claude/TP_A.iMessage_standalone_01067051080" ;;
                    TP_BTT)               WINDOW_NAME="btt";             PROJ_PATH="$HOME/claude/TP_BTT" ;;
                    TP_Infra_reduce_Project) WINDOW_NAME="infra";        PROJ_PATH="$HOME/claude/TP_Infra_reduce_Project" ;;
                    TP_skills)            WINDOW_NAME="skills";          PROJ_PATH="$HOME/claude/TP_skills" ;;
                    AppleTV_ScreenSaver.app) WINDOW_NAME="appletv";     PROJ_PATH="$HOME/claude/AppleTV_ScreenSaver.app" ;;
                    imsms.im-website)     WINDOW_NAME="imsms-web";       PROJ_PATH="$HOME/claude/imsms.im-website" ;;
                    TP_iTerm) WINDOW_NAME="auto-restart";  PROJ_PATH="$HOME/claude/TP_iTerm" ;;
                esac

                if [ -z "$WINDOW_NAME" ] || [ ! -d "$PROJ_PATH" ]; then
                    log "SKIP restart: unknown project or missing path: $RESTART_PROJECT"
                    continue
                fi

                # tmux claude-work 세션이 있는지 확인
                if ! tmux has-session -t claude-work 2>/dev/null; then
                    log "SKIP restart: claude-work tmux session not found"
                    continue
                fi

                # 해당 윈도우가 이미 있으면 kill 후 재생성, 없으면 새로 생성
                if tmux list-windows -t claude-work -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
                    tmux kill-window -t "claude-work:$WINDOW_NAME" 2>/dev/null
                    sleep 1
                fi

                # 연속 크래시 카운터 증가
                CRASH_COUNT_FILE="$CRASH_COUNT_DIR/${RESTART_PROJECT//[^a-zA-Z0-9_-]/_}"
                CURRENT_COUNT=0
                [ -f "$CRASH_COUNT_FILE" ] && CURRENT_COUNT=$(cat "$CRASH_COUNT_FILE" 2>/dev/null || echo 0)
                NEW_COUNT=$((CURRENT_COUNT + 1))
                echo "$NEW_COUNT" > "$CRASH_COUNT_FILE"

                # 연속 크래시 임계값 초과 시 intentional-stop 등록 (무한 루프 방지)
                if [ "$NEW_COUNT" -gt "$CRASH_MAX" ]; then
                    log "CRASH LOOP DETECTED: $RESTART_PROJECT (${NEW_COUNT}회) — intentional-stop 등록"
                    notify "⚠️ $RESTART_PROJECT 연속 ${NEW_COUNT}회 크래시 — 자동 복원 중단"
                    bash "$HOME/.claude/scripts/stop-session.sh" "$WINDOW_NAME" 2>/dev/null || true
                    continue
                fi

                tmux new-window -t claude-work -n "$WINDOW_NAME" -c "$PROJ_PATH" 2>/dev/null
                tmux set-window-option -t "claude-work:$WINDOW_NAME" automatic-rename off 2>/dev/null
                tmux send-keys -t "claude-work:$WINDOW_NAME" "bash ~/.claude/scripts/tab-status.sh starting $WINDOW_NAME && unset CLAUDECODE && claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions" Enter

                log "AUTO-RESTART: $RESTART_PROJECT → tmux window $WINDOW_NAME (연속 ${NEW_COUNT}/${CRASH_MAX}회)"
                notify "세션 자동 복구: $RESTART_PROJECT"
            done
        fi
    fi

    # 2. 시간 경과 동그라미 표시 (tab-states 파일 기반)
    #    1시간+ → 🟡  |  1일+ → 🔴  |  3일+ → 🔴⚪ 깜빡임
    NOW=$(date +%s)
    STATE_DIR="$HOME/.claude/tab-states"
    if [ -d "$STATE_DIR" ]; then
        # 고아 tab-states 정리: TTY가 사라진 파일 자동 삭제
        for STATE_FILE in "$STATE_DIR"/ttys*; do
            [ ! -f "$STATE_FILE" ] && continue
            TTY_NAME=$(basename "$STATE_FILE" .json)
            TTY_PATH="/dev/$TTY_NAME"
            if [ ! -c "$TTY_PATH" ]; then
                rm -f "$STATE_FILE"
                log "CLEANUP: orphan tab-state removed: $TTY_NAME"
                continue
            fi
            [ ! -w "$TTY_PATH" ] && continue

            TAB_STATUS=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null)
            TAB_PROJECT=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null)
            LAST_TS=$(cut -d'|' -f3 "$STATE_FILE" 2>/dev/null)
            [ -z "$LAST_TS" ] && continue

            AGE=$(( NOW - LAST_TS ))

            if [ $AGE -ge 259200 ]; then
                # 3일+ → 🔴⚪ 깜빡임 (1회만, 30초마다 반복됨)
                printf '\e]1;🔴 %s\a' "$TAB_PROJECT" > "$TTY_PATH" 2>/dev/null
                atomic_write "$STATE_FILE" "stale|${TAB_PROJECT}|${LAST_TS}"
                # 다음 30초에 ⚪로 바뀌도록 토글 파일
                TOGGLE_FILE="/tmp/.tab-blink-${TTY_NAME}"
                if [ -f "$TOGGLE_FILE" ]; then
                    printf '\e]1;⚪ %s\a' "$TAB_PROJECT" > "$TTY_PATH" 2>/dev/null
                    rm "$TOGGLE_FILE"
                else
                    printf '\e]1;🔴 %s\a' "$TAB_PROJECT" > "$TTY_PATH" 2>/dev/null
                    touch "$TOGGLE_FILE"
                fi
                printf '\e]6;1;bg;red;brightness;80\a\e]6;1;bg;green;brightness;80\a\e]6;1;bg;blue;brightness;80\a' > "$TTY_PATH" 2>/dev/null
            elif [ $AGE -ge 86400 ]; then
                # 24시간+ → 🔴
                printf '\e]1;🔴 %s\a' "$TAB_PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;200\a\e]6;1;bg;green;brightness;50\a\e]6;1;bg;blue;brightness;50\a' > "$TTY_PATH" 2>/dev/null
                atomic_write "$STATE_FILE" "idle|${TAB_PROJECT}|${LAST_TS}"
            elif [ $AGE -ge 3600 ]; then
                # 1시간+ → 🟡
                printf '\e]1;🟡 %s\a' "$TAB_PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;200\a\e]6;1;bg;green;brightness;150\a\e]6;1;bg;blue;brightness;0\a' > "$TTY_PATH" 2>/dev/null
                atomic_write "$STATE_FILE" "idle|${TAB_PROJECT}|${LAST_TS}"
            elif [ $AGE -ge 600 ]; then
                # 10분+ → ⚪ 흰색
                printf '\e]1;⚪ %s\a' "$TAB_PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;220\a\e]6;1;bg;green;brightness;220\a\e]6;1;bg;blue;brightness;220\a' > "$TTY_PATH" 2>/dev/null
                atomic_write "$STATE_FILE" "idle|${TAB_PROJECT}|${LAST_TS}"
            fi
        done
    fi

    # 3. 좀비 프로세스 감지 (72시간 이상 + tty 없음)
    ZOMBIES=$(ps -eo pid,tty,etime,command 2>/dev/null | grep "[c]laude" | grep -v "Claude.app\|Helper\|watchdog\|auto-restore" | awk '{
        # etime 형식: DD-HH:MM:SS 또는 HH:MM:SS 또는 MM:SS
        split($3, parts, "-");
        days = 0;
        if (length(parts) == 2) { days = parts[1]+0; }
        if (days >= 3 && $2 == "??") print $1, $4
    }' 2>/dev/null || true)

    if [ -n "$ZOMBIES" ]; then
        log "ZOMBIE DETECTED: $ZOMBIES"
    fi

    # 4. iTerm2 생존 확인 (ps -A 사용 — tmux sandbox에서 pgrep -x 오탐 방지)
    if ! ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
        log "WARNING: iTerm2 not running"
    fi

    # monitor 창 소실 감지 및 자동 복구
    if tmux has-session -t claude-work 2>/dev/null; then
        if ! tmux list-windows -t claude-work -F "#{window_name}" 2>/dev/null | grep -q "^monitor$"; then
            log "MONITOR 창 없음 — 자동 복구"
            tmux new-window -t claude-work -n monitor -c "$HOME/claude" 2>/dev/null && \
                tmux send-keys -t "claude-work:monitor" "bash ~/.claude/scripts/tab-status.sh starting monitor && unset CLAUDECODE && claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions" Enter && \
                log "MONITOR 창 복구 완료" || \
                log "ERROR: MONITOR 창 복구 실패"
        fi
    fi

    # stderr.log 로테이션 (매 루프마다 체크)
    rotate_stderr_log

    # 30초 대기
    sleep 30
done
