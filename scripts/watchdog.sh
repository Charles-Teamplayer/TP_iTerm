#!/bin/bash
# Claude Code Watchdog (VERDANDI-5 검증 + 민수 구현)
# LaunchAgent KeepAlive로 보호됨

LOG_FILE="$HOME/.claude/logs/watchdog.log"
REGISTRY="$HOME/.claude/active-sessions.json"
RESTART_COOLDOWN=60  # 같은 프로젝트 재시작 간 최소 대기시간(초)
RESTART_LOG="$HOME/.claude/logs/restart-history.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
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
                if [ -n "$CRASH_TTY" ] && [ -c "/dev/$CRASH_TTY" ]; then
                    # TTY에 직접 crashed 상태 표시 (정확한 탭 타겟팅)
                    (
                        for i in $(seq 1 10); do
                            # claude 재시작 감지 시 조기 탈출
                            if ps -o tty,command -ax | grep "$CRASH_TTY" | grep -q "[c]laude" 2>/dev/null; then
                                printf '\e]1;🔄 %s\a' "$CRASH_PROJECT" > "/dev/$CRASH_TTY" 2>/dev/null
                                exit 0
                            fi
                            printf '\e]1;⚪ %s [CRASHED]\a' "$CRASH_PROJECT" > "/dev/$CRASH_TTY" 2>/dev/null
                            sleep 1
                            printf '\e]1;🔴 %s [CRASHED]\a' "$CRASH_PROJECT" > "/dev/$CRASH_TTY" 2>/dev/null
                            sleep 1
                        done
                        printf '\e]1;🔴 %s [CRASHED]\a' "$CRASH_PROJECT" > "/dev/$CRASH_TTY" 2>/dev/null
                    ) &
                else
                    bash "$HOME/.claude/scripts/tab-status.sh" crashed "$CRASH_PROJECT" &
                fi
            done

            # 크래시된 세션 재시작은 auto-restore.sh가 담당
            # watchdog은 감지 + 알림만
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $CRASHED" >> "$RESTART_LOG"
        fi
    fi

    # 2. 시간 경과 세션 상태 갱신 (idle: 1일+, stale: 7일+)
    AGE_RESULT=$(bash "$HOME/.claude/scripts/session-registry.sh" age-check 2>/dev/null || true)
    if [ -n "$AGE_RESULT" ]; then
        echo "$AGE_RESULT" | while IFS=: read -r level project tty; do
            if [ -n "$tty" ] && [ -c "/dev/$tty" ]; then
                case "$level" in
                    STALE)
                        printf '\e]1;⚫ %s [7d+]\a' "$project" > "/dev/$tty" 2>/dev/null
                        ;;
                    IDLE)
                        printf '\e]1;🟠 %s [1d+]\a' "$project" > "/dev/$tty" 2>/dev/null
                        ;;
                esac
            fi
        done
    fi

    # 3. 좀비 프로세스 감지 (72시간 이상 + tty 없음)
    ZOMBIES=$(ps aux | grep "[c]laude" | awk '{
        split($10, t, ":");
        if (length(t) >= 3) {
            hours = t[1];
            if (hours+0 > 72 && $7 == "??") print $2, $11
        }
    }' 2>/dev/null || true)

    if [ -n "$ZOMBIES" ]; then
        log "ZOMBIE DETECTED: $ZOMBIES"
    fi

    # 3. iTerm2 생존 확인
    if ! pgrep -x "iTerm2" > /dev/null; then
        log "WARNING: iTerm2 not running"
    fi

    # 30초 대기
    sleep 30
done
