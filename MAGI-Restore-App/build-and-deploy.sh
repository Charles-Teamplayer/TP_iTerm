#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building..."
swift build 2>&1 | tail -5

BINARY=".build/debug/TPiTermRestore"
REPO_APP="$SCRIPT_DIR/../TP_iTerm_Restore.app/Contents/MacOS/TP_iTerm_Restore"
APPS_APP="/Applications/TP_iTerm_Restore.app/Contents/MacOS/TP_iTerm_Restore"

cp "$BINARY" "$REPO_APP" && echo "✅ repo updated"
[ -d "/Applications/TP_iTerm_Restore.app" ] && cp "$BINARY" "$APPS_APP" && echo "✅ /Applications updated"

# 실행 중이면 재시작
if pgrep -f "TP_iTerm_Restore" > /dev/null 2>&1; then
    pkill -f "TP_iTerm_Restore" 2>/dev/null || true
    sleep 0.5
    open /Applications/TP_iTerm_Restore.app
    echo "✅ app restarted"
fi
