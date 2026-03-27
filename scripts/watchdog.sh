#!/bin/bash
# Claude Code Watchdog (VERDANDI-5 검증 + 민수 구현)
# LaunchAgent KeepAlive로 보호됨

LOG_FILE="$HOME/.claude/logs/watchdog.log"
REGISTRY="$HOME/.claude/active-sessions.json"
RESTART_COOLDOWN=60  # 같은 프로젝트 재시작 간 최소 대기시간(초)
RESTART_LOG="$HOME/.claude/logs/restart-history.log"
CRASH_COUNT_DIR="$HOME/.claude/crash-counts"  # 연속 크래시 카운터 (타임스탬프 기반 만료)
CRASH_MAX=5  # 이 횟수 초과 시 intentional-stop 등록
CRASH_COUNT_TTL=86400  # 24시간 이상된 카운터 자동 만료
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
    echo "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
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

# Watchdog 재시작 시 오래된(24h+) crash-count만 정리 (최근 카운터는 보존 → 크래시 루프 방지)
NOW_INIT=$(date +%s)
for cf in "$CRASH_COUNT_DIR"/*; do
    [ ! -f "$cf" ] && continue
    CF_TS=$(cut -d'|' -f2 "$cf" 2>/dev/null || echo 0)
    if [ $(( NOW_INIT - ${CF_TS:-0} )) -gt "$CRASH_COUNT_TTL" ]; then
        rm -f "$cf"
    fi
done
log "Crash-count 정리 완료 (24h+ 만료)"

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

                # activated-sessions.json에서 프로젝트명으로 경로 조회
                # window 이름 = 디렉토리 basename (= RESTART_PROJECT)
                PROJ_PATH=$(python3 -c "
import json, os, sys
name = sys.argv[1]
path = os.path.expanduser('~/.claude/activated-sessions.json')
for candidate in [path, path + '.bak']:
    try:
        data = json.load(open(candidate))
        for p in data.get('activated', []):
            if os.path.basename(p) == name:
                print(p)
                sys.exit(0)
    except Exception:
        continue
" "$RESTART_PROJECT" 2>/dev/null)
                WINDOW_NAME="$RESTART_PROJECT"

                if [ -z "$PROJ_PATH" ] || [ ! -d "$PROJ_PATH" ]; then
                    log "SKIP restart: $RESTART_PROJECT not in activated-sessions or path missing"
                    continue
                fi

                # window-groups.json에서 이 윈도우가 속한 세션 + 대기목록 여부 확인
                SESSION_INFO=$(python3 -c "
import json, os, sys
name = sys.argv[1]
path = os.path.expanduser('~/.claude/window-groups.json')
try:
    groups = json.load(open(path))
    for g in groups:
        if name in g.get('profileNames', []):
            waiting = 'yes' if g.get('isWaitingList') or g.get('sessionName','') == '__waiting__' else 'no'
            print(waiting + '|' + g.get('sessionName','claude-work'))
            sys.exit(0)
except Exception:
    pass
print('no|claude-work')
" "$WINDOW_NAME" 2>/dev/null)
                IS_WAITING=$(echo "$SESSION_INFO" | cut -d'|' -f1)
                TARGET_SESSION=$(echo "$SESSION_INFO" | cut -d'|' -f2)
                [ -z "$TARGET_SESSION" ] && TARGET_SESSION="claude-work"

                if [ "$IS_WAITING" = "yes" ]; then
                    log "SKIP restart: $WINDOW_NAME — 대기목록 세션"
                    continue
                fi

                # 해당 tmux 세션이 존재하는지 확인
                if ! tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
                    log "SKIP restart: $TARGET_SESSION tmux session not found"
                    continue
                fi

                # 해당 윈도우가 타겟 세션에 없으면 재시작 스킵 (비활성 세션)
                if ! tmux list-windows -t "$TARGET_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
                    log "SKIP restart: $WINDOW_NAME — $TARGET_SESSION에 창 없음"
                    continue
                fi
                # 기존 창 kill 후 재생성
                # BUG#24 fix: window name에 '.'이 있으면 tmux가 pane 구분자로 오인 → window_id(@N) 기반 kill
                WIN_ID_KILL=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$WINDOW_NAME" '$2==w{print $1; exit}')
                if [ -n "$WIN_ID_KILL" ]; then
                    tmux kill-window -t "$WIN_ID_KILL" 2>/dev/null
                else
                    tmux kill-window -t "$TARGET_SESSION:$WINDOW_NAME" 2>/dev/null
                fi
                sleep 1

                # 연속 크래시 카운터 증가 (COUNT|TIMESTAMP 형식, 24h 만료)
                CRASH_COUNT_FILE="$CRASH_COUNT_DIR/${RESTART_PROJECT//[^a-zA-Z0-9_-]/_}"
                CURRENT_COUNT=0
                CC_NOW=$(date +%s)
                if [ -f "$CRASH_COUNT_FILE" ]; then
                    CC_VAL=$(cat "$CRASH_COUNT_FILE" 2>/dev/null || echo "0|0")
                    CC_CNT=$(echo "$CC_VAL" | cut -d'|' -f1)
                    CC_TS=$(echo "$CC_VAL" | cut -d'|' -f2)
                    # 24시간 이상된 카운터는 리셋
                    if [ $(( CC_NOW - ${CC_TS:-0} )) -gt "$CRASH_COUNT_TTL" ]; then
                        CURRENT_COUNT=0
                    else
                        CURRENT_COUNT=${CC_CNT:-0}
                    fi
                fi
                NEW_COUNT=$((CURRENT_COUNT + 1))
                echo "${NEW_COUNT}|${CC_NOW}" > "$CRASH_COUNT_FILE"

                # 연속 크래시 임계값 초과 시 intentional-stop 등록 (무한 루프 방지)
                if [ "$NEW_COUNT" -gt "$CRASH_MAX" ]; then
                    log "CRASH LOOP DETECTED: $RESTART_PROJECT (${NEW_COUNT}회) — intentional-stop 등록"
                    notify "⚠️ $RESTART_PROJECT 연속 ${NEW_COUNT}회 크래시 — 자동 복원 중단"
                    bash "$HOME/.claude/scripts/stop-session.sh" "$WINDOW_NAME" 2>/dev/null || true
                    continue
                fi

                tmux new-window -t "$TARGET_SESSION" -n "$WINDOW_NAME" -c "$PROJ_PATH" 2>/dev/null
                # BUG#25 fix: 새 창 index 조회 후 index 기반 set-window-option/send-keys (dot 이름 안전)
                WIN_IDX_NEW=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_index}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$WINDOW_NAME" '$2==w{print $1; exit}')
                if [ -n "$WIN_IDX_NEW" ]; then
                    tmux set-window-option -t "$TARGET_SESSION:$WIN_IDX_NEW" automatic-rename off 2>/dev/null
                    tmux send-keys -t "$TARGET_SESSION:$WIN_IDX_NEW" "bash ~/.claude/scripts/tab-status.sh starting '$WINDOW_NAME' && unset CLAUDECODE && claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions" Enter
                else
                    tmux set-window-option -t "$TARGET_SESSION:$WINDOW_NAME" automatic-rename off 2>/dev/null
                    tmux send-keys -t "$TARGET_SESSION:$WINDOW_NAME" "bash ~/.claude/scripts/tab-status.sh starting '$WINDOW_NAME' && unset CLAUDECODE && claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions" Enter
                fi

                log "AUTO-RESTART: $RESTART_PROJECT → $TARGET_SESSION:$WINDOW_NAME (연속 ${NEW_COUNT}/${CRASH_MAX}회)"
                notify "세션 자동 복구: $RESTART_PROJECT"
            done
        fi
    fi

    # 2. 시간 경과 표시 (v3 tab-color/states JSON 기반 → set-color.sh 경유)
    #    10분+ → idle_10m  |  1시간+ → idle_1h  |  1일+ → idle_1d  |  3일+ → idle_3d
    NOW=$(date +%s)
    STATE_DIR="$HOME/.claude/tab-color/states"
    LEGACY_STATE_DIR="$HOME/.claude/tab-states"
    if [ -d "$STATE_DIR" ]; then
        # Claude Code 보호: tmux 패인에 실제로 속한 TTY만 처리 (s008 등 자체 터미널 보호)
        TMUX_PANE_TTYS=$(tmux list-panes -a -F "#{pane_tty}" 2>/dev/null | sort -u)
        for STATE_FILE in "$STATE_DIR"/*.json; do
            [ ! -f "$STATE_FILE" ] && continue
            TTY_NAME=$(basename "$STATE_FILE" .json)
            TTY_PATH="/dev/$TTY_NAME"
            if [ ! -c "$TTY_PATH" ]; then
                rm -f "$STATE_FILE"
                log "CLEANUP: orphan tab-color state removed: $TTY_NAME"
                continue
            fi
            [ ! -w "$TTY_PATH" ] && continue
            # tmux 패인에 없는 TTY는 건드리지 않음 (Claude Code 자체 터미널 보호)
            if ! echo "$TMUX_PANE_TTYS" | grep -qF "$TTY_PATH"; then
                rm -f "$STATE_FILE"
                log "CLEANUP: non-tmux TTY state removed (self-protection): $TTY_NAME"
                continue
            fi

            if command -v jq &>/dev/null; then
                TAB_PROJECT=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)
                LAST_TS_ISO=$(jq -r '.timestamp // ""' "$STATE_FILE" 2>/dev/null)
                TAB_TYPE=$(jq -r '.type // ""' "$STATE_FILE" 2>/dev/null)
            else
                TAB_PROJECT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('project',''))" 2>/dev/null)
                LAST_TS_ISO=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('timestamp',''))" 2>/dev/null)
                TAB_TYPE=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('type',''))" 2>/dev/null)
            fi
            [ -z "$LAST_TS_ISO" ] && continue
            # active/working: PID가 살아있을 때만 aging 스킵 (죽은 세션은 aging 진행)
            if [ "$TAB_TYPE" = "active" ] || [ "$TAB_TYPE" = "working" ]; then
                TAB_PID=$(jq -r '.pid // "0"' "$STATE_FILE" 2>/dev/null || echo "0")
                if [ "$TAB_PID" -gt 0 ] && kill -0 "$TAB_PID" 2>/dev/null; then
                    continue  # PID 살아있음 → aging 스킵
                fi
                # PID 없거나 죽었음 → aging 진행
            fi

            LAST_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS_ISO" +%s 2>/dev/null || echo 0)
            [ "$LAST_TS" = "0" ] && continue

            AGE=$(( NOW - LAST_TS ))

            # 이미 해당 idle 상태면 재호출 스킵 (불필요한 ESC 반복 방지)
            if [ $AGE -ge 259200 ]; then
                AGING_STATE="idle_3d"
            elif [ $AGE -ge 86400 ]; then
                AGING_STATE="idle_1d"
            elif [ $AGE -ge 3600 ]; then
                AGING_STATE="idle_1h"
            elif [ $AGE -ge 600 ]; then
                AGING_STATE="idle_10m"
            else
                continue
            fi
            # 이미 같은 idle 상태면 스킵 (30초마다 재호출 불필요)
            [ "$TAB_TYPE" = "$AGING_STATE" ] && continue
            # set-color.sh 경유: state 파일 갱신 + config 색상 사용
            TAB_TTY="$TTY_PATH" bash "$HOME/.claude/tab-color/engine/set-color.sh" "$AGING_STATE" "$TAB_PROJECT" 2>/dev/null &
        done
    fi
    # 레거시 tab-states 잔존 파일 일괄 정리
    if [ -d "$LEGACY_STATE_DIR" ]; then
        LEGACY_COUNT=$(find "$LEGACY_STATE_DIR" -name 'ttys*' 2>/dev/null | wc -l | tr -d ' ')
        if [ "${LEGACY_COUNT:-0}" -gt 0 ]; then
            rm -f "$LEGACY_STATE_DIR"/ttys* 2>/dev/null
            log "CLEANUP: legacy tab-states ${LEGACY_COUNT}개 정리"
        fi
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

    # monitor 창 소실 감지 및 자동 복구 (모든 active 세션)
    ACTIVE_SESSIONS_MON=$(python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            print(sn)
except: pass
" 2>/dev/null)
    [ -z "$ACTIVE_SESSIONS_MON" ] && ACTIVE_SESSIONS_MON="claude-work"

    for MON_SESSION in $ACTIVE_SESSIONS_MON; do
        if tmux has-session -t "$MON_SESSION" 2>/dev/null; then
            if ! tmux list-windows -t "$MON_SESSION" -F "#{window_name}" 2>/dev/null | grep -q "^monitor$"; then
                log "MONITOR 창 없음 ($MON_SESSION) — 자동 복구"
                if tmux new-window -t "$MON_SESSION" -n monitor -c "$HOME/claude" 2>/dev/null; then
                    tmux set-window-option -t "$MON_SESSION:monitor" automatic-rename off 2>/dev/null
                    tmux move-window -s "$MON_SESSION:monitor" -t "$MON_SESSION:999" 2>/dev/null || true
                    log "MONITOR 창 복구 완료 ($MON_SESSION)"
                else
                    log "ERROR: MONITOR 창 복구 실패 ($MON_SESSION)"
                fi
            else
                # monitor 창이 999번이 아니면 이동
                MON_IDX=$(tmux list-windows -t "$MON_SESSION" -F "#{window_index} #{window_name}" 2>/dev/null | awk '/^[0-9]+ monitor$/{print $1}')
                if [ -n "$MON_IDX" ] && [ "$MON_IDX" != "999" ]; then
                    tmux move-window -s "$MON_SESSION:monitor" -t "$MON_SESSION:999" 2>/dev/null || true
                fi
            fi
        fi
    done

    # 5. tmux CC 클라이언트 연결 상태 모니터링 (모든 active 세션)
    for CC_SESSION in $ACTIVE_SESSIONS_MON; do
        if tmux has-session -t "$CC_SESSION" 2>/dev/null; then
            CLIENT_COUNT=$(tmux list-clients -t "$CC_SESSION" -F "#{client_name}" 2>/dev/null | wc -l | tr -d ' ')
            if [ "${CLIENT_COUNT:-0}" -eq 0 ]; then
                CC_FIX_LOCK="/tmp/.cc-fix-last-${CC_SESSION//[^a-zA-Z0-9]/_}"
                LAST_FIX=0
                [ -f "$CC_FIX_LOCK" ] && LAST_FIX=$(cat "$CC_FIX_LOCK" 2>/dev/null || echo 0)
                NOW_FIX=$(date +%s)
                if [ $((NOW_FIX - LAST_FIX)) -gt 120 ]; then
                    log "WARNING: $CC_SESSION 클라이언트 없음 — 자동 CC 재연결 시도"
                    echo "$NOW_FIX" > "$CC_FIX_LOCK"
                    TMUX_SESSION="$CC_SESSION" bash "$HOME/.claude/scripts/cc-fix.sh" 2>/dev/null &
                fi
            fi
        fi
    done

    # stderr.log 로테이션 (매 루프마다 체크)
    rotate_stderr_log

    # 30초 대기
    sleep 30
done
