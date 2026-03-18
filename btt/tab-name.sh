#!/bin/bash
# BTT Touch Bar용 iTerm2 탭 이름 반환
# 사용: tab-name.sh <탭번호>
# 탭 없으면 빈 문자열 반환 (BTT가 버튼 숨김)

N=${1:-1}

osascript << EOF
tell application "iTerm2"
  try
    set w to current window
    if $N > (count of tabs of w) then return ""
    set s to current session of tab $N of w
    set n to name of s
    -- 이모지/프리픽스 제거하고 프로젝트명만
    set n to do shell script "echo " & quoted form of n & " | sed 's/[✳⚡💤🔴🟢🟡🟠⚫] //g' | sed 's/ (claude)//g' | cut -c1-12"
    return n
  on error
    return ""
  end try
end tell
EOF
