#!/bin/bash
# tab-status.sh v3 wrapper — 하위호환 유지
# 실제 로직은 ~/.claude/tab-color/engine/set-color.sh
exec bash "$HOME/.claude/tab-color/engine/set-color.sh" "$@"
