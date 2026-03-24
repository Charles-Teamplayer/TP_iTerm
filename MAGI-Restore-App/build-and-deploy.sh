#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building..."
swift build 2>&1 | tail -5

BINARY=".build/debug/TPiTermRestore"
APP_BUNDLE="/Applications/TP_iTerm_Restore.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
TARGET_NAME="TP_iTerm_Restore"  # Info.plist CFBundleExecutable과 일치해야 함

# repo 앱 번들 업데이트
REPO_APP="$SCRIPT_DIR/../TP_iTerm_Restore.app/Contents/MacOS/$TARGET_NAME"
cp "$BINARY" "$REPO_APP" && echo "✅ repo updated"

# /Applications 앱 번들 업데이트
if [ -d "$APP_BUNDLE" ]; then
    # 구 바이너리 정리 (CFBundleExecutable과 다른 이름의 바이너리 제거)
    find "$MACOS_DIR" -type f -perm +111 ! -name "$TARGET_NAME" -delete 2>/dev/null || true

    cp "$BINARY" "$MACOS_DIR/$TARGET_NAME" && echo "✅ /Applications updated"

    # Info.plist 동기화 (CFBundleExecutable 불일치 방지)
    cp "$SCRIPT_DIR/../TP_iTerm_Restore.app/Contents/Info.plist" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null && echo "✅ Info.plist synced"

    # 깨진 코드서명 잔여물 제거 후 ad-hoc 재서명
    rm -rf "$APP_BUNDLE/Contents/_CodeSignature" 2>/dev/null || true
    codesign --force --sign - --deep "$APP_BUNDLE" 2>&1 && echo "✅ codesign applied"
fi

# 실행 중이면 재시작
if pgrep -f "TP_iTerm_Restore" > /dev/null 2>&1; then
    pkill -f "TP_iTerm_Restore" 2>/dev/null || true
    sleep 1
    open "$APP_BUNDLE"
    echo "✅ app restarted"
fi
