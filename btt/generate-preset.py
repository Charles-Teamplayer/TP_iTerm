#!/usr/bin/env python3
"""
BTT Touch Bar 프리셋 생성 — iTerm2 탭 네비게이션
최대 20개 탭 버튼 생성 (탭 없으면 자동 숨김)
"""

import json
import uuid
import os

SCRIPTS_DIR = os.path.expanduser("~/claude/TP_iTerm/btt")
MAX_TABS = 20

# 탭 색상 (어두운 배경에 선명한 텍스트)
BTN_COLOR   = "50.000000, 50.000000, 50.000000, 255.000000"
BTN_COLOR_1_9  = "30.000000, 80.000000, 30.000000, 255.000000"   # 1-9: 초록톤
BTN_COLOR_10UP = "80.000000, 40.000000, 0.000000, 255.000000"    # 10+: 주황톤
TEXT_COLOR  = "255.000000, 255.000000, 255.000000, 255.000000"


def make_tab_button(n):
    btn_color = BTN_COLOR_1_9 if n <= 9 else BTN_COLOR_10UP
    label_script = f'bash "{SCRIPTS_DIR}/tab-name.sh" {n}'
    goto_script  = f'bash "{SCRIPTS_DIR}/tab-goto.sh" {n}'

    return {
        "BTTTriggerType": 630,
        "BTTTriggerName": f"iTerm Tab {n}",
        "BTTEnabled": 1,
        "BTTEnabled2": 1,
        "BTTOrder": n - 1,
        "BTTUUID": str(uuid.uuid4()).upper(),
        "BTTTriggerConfig": {
            "BTTTouchBarButtonName": str(n),
            "BTTTouchBarButtonColor": btn_color,
            "BTTTouchBarButtonTextColor": TEXT_COLOR,
            "BTTTouchBarButtonFontSize": 13,
            "BTTTouchBarItemIconType": 2,
            "BTTTouchBarScriptType": 2,           # shell script for label
            "BTTTouchBarScript": label_script,
            "BTTTouchBarButtonRefreshInterval": 2, # 2초마다 탭 이름 갱신
            "BTTTouchBarAlwaysShowButton": 0,      # 빈 문자열 반환 시 숨김
            "BTTTouchBarButtonWidth": 72,
            "BTTTouchBarButtonIsInGroup": 1,
        },
        "BTTActions": [
            {
                "BTTGestureActionType": 167,  # Run Shell Script
                "BTTShellTaskActionScript": goto_script,
                "BTTEnabled": 1,
                "BTTEnabled2": 1,
                "BTTOrder": 0,
                "BTTUUID": str(uuid.uuid4()).upper(),
            }
        ]
    }


def make_scroll_group(buttons):
    """탭 버튼들을 감싸는 스크롤 그룹"""
    return {
        "BTTTriggerType": 639,   # Scroll Group
        "BTTTriggerName": "iTerm Tabs",
        "BTTEnabled": 1,
        "BTTEnabled2": 1,
        "BTTOrder": 0,
        "BTTUUID": str(uuid.uuid4()).upper(),
        "BTTTriggerConfig": {
            "BTTTouchBarButtonColor": "0.000000, 0.000000, 0.000000, 0.000000",
            "BTTTouchBarButtonIsInGroup": 0,
        },
        "BTTSubTriggers": buttons
    }


def make_app_group(sub_triggers):
    """com.googlecode.iterm2 앱 전용 그룹"""
    return {
        "BTTTriggerType": 643,
        "BTTTriggerName": "iTerm2",
        "BTTAppBundleIdentifier": "com.googlecode.iterm2",
        "BTTEnabled": 1,
        "BTTEnabled2": 1,
        "BTTOrder": 0,
        "BTTUUID": str(uuid.uuid4()).upper(),
        "BTTAdditionalConfiguration": "13",  # 앱 활성 시에만 표시
        "BTTSubTriggers": sub_triggers
    }


if __name__ == "__main__":
    buttons = [make_tab_button(n) for n in range(1, MAX_TABS + 1)]
    scroll_group = make_scroll_group(buttons)
    app_group = make_app_group([scroll_group])
    preset = [app_group]

    out_path = os.path.join(SCRIPTS_DIR, "iterm-tabs.bttpreset")
    with open(out_path, "w") as f:
        json.dump(preset, f, indent=2, ensure_ascii=False)

    print(f"✅ 프리셋 생성: {out_path}")
    print(f"   탭 버튼: {MAX_TABS}개 (없는 탭은 자동 숨김)")
    print(f"\n📋 BTT에서 임포트:")
    print(f"   BTT Preferences → Presets → Import → {out_path}")
    print(f"   또는: open '{out_path}'")
