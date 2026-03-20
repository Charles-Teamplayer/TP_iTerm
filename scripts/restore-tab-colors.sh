#!/bin/bash
# tab-states 기반 탭 색상 복원
# 호출 시점: tmux -CC reattach 후, TP_iTerm_Restore 복원 후
STATE_DIR="$HOME/.claude/tab-states"
[ ! -d "$STATE_DIR" ] && exit 0

RESTORED=0
for STATE_FILE in "$STATE_DIR"/ttys*; do
    [ ! -f "$STATE_FILE" ] && continue
    TTY_NAME=$(basename "$STATE_FILE")
    TTY_PATH="/dev/$TTY_NAME"
    [ ! -c "$TTY_PATH" ] || [ ! -w "$TTY_PATH" ] && continue

    STATUS=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null)
    PROJECT=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null)
    [ -z "$STATUS" ] || [ -z "$PROJECT" ] && continue

    case "$STATUS" in
        active)   R=0;   G=220; B=0   ;;
        working)  R=255; G=230; B=0   ;;
        waiting)  R=0;   G=120; B=255 ;;
        idle)     R=255; G=140; B=0   ;;
        stale)    R=80;  G=80;  B=80  ;;
        starting) R=0;   G=160; B=255 ;;
        crashed)  R=255; G=0;   B=0   ;;
        *)        continue ;;
    esac

    printf '\e]1;%s\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
    printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
        "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null
    RESTORED=$((RESTORED + 1))
done

echo "restored $RESTORED tab colors"
