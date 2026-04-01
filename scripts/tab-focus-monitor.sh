#!/opt/homebrew/bin/bash
# iTerm2 탭 포커스 감지 데몬 v6 — 다중 tmux 세션 지원
# tmux display-message로 활성 윈도우 감지 → waiting/attention → active 복원

STATE_DIR="$HOME/.claude/tab-color/states"
LOG="$HOME/.claude/logs/tab-focus-monitor.log"
WINDOW_GROUPS="$HOME/.claude/window-groups.json"
mkdir -p "$(dirname "$LOG")"

rotate_log() {
    local logfile="$1"
    if [ -f "$logfile" ]; then
        local size=$(wc -c < "$logfile")
        local lines=$(wc -l < "$logfile")
        # 라인 수 초과 (5000줄) 또는 파일 크기 초과 (150KB)
        if [ "$lines" -gt 5000 ] || [ "$size" -gt 153600 ]; then
            tail -n 1000 "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
        fi
    fi
}

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
rotate_log "$LOG"
log "=== 포커스 모니터 v6 시작 (다중 세션 지원) ==="

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 세션별 마지막 윈도우 인덱스 추적 (연관 배열)
declare -A LAST_WIN_MAP

# 활성 세션 목록 읽기 (window-groups.json 기반, 30초마다 갱신)
get_active_sessions() {
    local _out
    if [ -f "$WINDOW_GROUPS" ]; then
        _out=$(_TFM_WG="$WINDOW_GROUPS" python3 -c "
import json, os
try:
    with open(os.environ['_TFM_WG']) as _f:
        groups = json.load(_f)
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            print(sn)
except: pass
" 2>/dev/null)
    fi
    # fallback: json 파싱 실패 시에만 claude-work 보장
    if [ -z "$_out" ]; then
        echo "claude-work"
    else
        echo "$_out"
    fi
}

SESSIONS_CACHE=""
SESSIONS_CACHE_TS=0

while true; do
    NOW=$(date +%s)

    # 30초마다 세션 목록 갱신
    if [ $(( NOW - SESSIONS_CACHE_TS )) -ge 30 ] || [ -z "$SESSIONS_CACHE" ]; then
        SESSIONS_CACHE=$(get_active_sessions | sort -u)
        SESSIONS_CACHE_TS=$NOW
    fi

    ANY_CHANGED=0
    while IFS= read -r TMUX_SESSION; do
        [ -z "$TMUX_SESSION" ] && continue

        # tmux 세션 존재 확인
        if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            continue
        fi

        # 현재 활성 윈도우 인덱스
        CUR_WIN=$(tmux display-message -t "$TMUX_SESSION" -p '#{window_index}' 2>/dev/null)
        [ -z "$CUR_WIN" ] && continue

        # 윈도우 변경 감지
        LAST="${LAST_WIN_MAP[$TMUX_SESSION]:-}"
        if [ "$CUR_WIN" = "$LAST" ]; then
            continue
        fi
        LAST_WIN_MAP[$TMUX_SESSION]="$CUR_WIN"
        ANY_CHANGED=1

        # 새로 포커스된 윈도우의 모든 pane TTY 확인
        while IFS= read -r PANE_TTY; do
            [ -z "$PANE_TTY" ] && continue
            TTY_NAME=$(basename "$PANE_TTY")
            STATE_FILE="${STATE_DIR}/${TTY_NAME}.json"
            [ ! -f "$STATE_FILE" ] && continue

            # BUG#5 fix: state file 2회 읽기 → 1회 통합 (race condition 제거)
            _TAB_DATA=$(_TFM_SF="$STATE_FILE" python3 -c "
import json, os
try:
    with open(os.environ['_TFM_SF']) as _f:
        d=json.load(_f)
    print(d.get('type',''))
    print(d.get('project',''))
except:
    print(''); print('')
" 2>/dev/null)
            TAB_STATUS=$(printf '%s' "$_TAB_DATA" | sed -n '1p')
            TAB_PROJECT=$(printf '%s' "$_TAB_DATA" | sed -n '2p')

            case "$TAB_STATUS" in
                waiting|attention|idle_10m|idle_1h|idle_1d|idle_3d|starting)
                    if [ -c "$PANE_TTY" ]; then
                        # flash 종료
                        FLASH_PID_FILE="/tmp/tab-flash-${TTY_NAME}.pid"
                        if [ -f "$FLASH_PID_FILE" ]; then
                            FLASH_PID=$(cat "$FLASH_PID_FILE" 2>/dev/null | tr -d ' ')
                            # iter59: FLASH_PID 숫자 검증 (음수/비숫자 방어)
                            [[ "$FLASH_PID" =~ ^[0-9]+$ ]] && [ "$FLASH_PID" -gt 0 ] && kill "$FLASH_PID" 2>/dev/null
                            rm -f "$FLASH_PID_FILE"
                        fi
                        # active 복원
                        TAB_TTY="$PANE_TTY" bash "$HOME/.claude/tab-color/engine/set-color.sh" active "$TAB_PROJECT"
                        log "${TAB_STATUS} → active ($TAB_PROJECT, $TTY_NAME, $TMUX_SESSION:$CUR_WIN)"
                    fi
                    ;;
            esac
        done < <(tmux list-panes -t "${TMUX_SESSION}:${CUR_WIN}" -F '#{pane_tty}' 2>/dev/null)

    done <<< "$SESSIONS_CACHE"

    sleep 1
done
