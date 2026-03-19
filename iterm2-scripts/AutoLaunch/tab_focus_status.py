#!/usr/bin/env python3
"""
iTerm2 탭 포커스 감지 → 배지 관리 (user.badge 변수만 사용)
TTY 직접 쓰기 제거 — tmux -CC 모드 충돌 방지
"""

import iterm2
import os
import json
import asyncio

CONFIG_PATH = os.path.expanduser("~/.claude/config/iterm-config.json")
_config = {}
_config_mtime = 0


def load_config():
    global _config, _config_mtime
    try:
        st = os.stat(CONFIG_PATH)
        if st.st_mtime != _config_mtime:
            with open(CONFIG_PATH) as f:
                _config = json.load(f)
            _config_mtime = st.st_mtime
    except (OSError, json.JSONDecodeError):
        pass
    return _config


async def config_reloader():
    while True:
        load_config()
        await asyncio.sleep(1)


async def clear_badge(session):
    """배지 클리어: user.badge 변수만 (TTY 직접 쓰기 금지 — tmux CC 충돌)"""
    cfg = load_config()
    if not cfg.get("badge_enabled", True):
        return
    try:
        await session.async_set_variable("user.badge", "")
    except Exception:
        pass


async def main(connection):
    app = await iterm2.async_get_app(connection)
    asyncio.get_running_loop().create_task(config_reloader())
    load_config()

    async with iterm2.FocusMonitor(connection) as monitor:
        while True:
            update = await monitor.async_get_next_update()
            if update.active_session_changed:
                session_id = update.active_session_changed.session_id
                session = app.get_session_by_id(session_id)
                if session is None:
                    continue
                try:
                    await clear_badge(session)
                except Exception:
                    pass


iterm2.run_forever(main)
