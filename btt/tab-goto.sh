#!/bin/bash
# BTT Touch Bar용 iTerm2 탭 이동
# 사용: tab-goto.sh <탭번호>

N=${1:-1}

osascript << EOF
tell application "iTerm2"
  try
    set w to current window
    if $N > (count of tabs of w) then return
    select tab $N of w
    activate
  end try
end tell
EOF
