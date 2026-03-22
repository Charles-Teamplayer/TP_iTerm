#!/usr/bin/env python3
"""
iTerm2 탭 포커스 감지 → 색상 복원 + 배지 클리어
탭 클릭 시 waiting/attention → active(초록) 자동 전환
"""

import iterm2
import os
import json
import asyncio
import signal
import subprocess
import time

STATE_DIR = os.path.expanduser("~/.claude/tab-color/states")
SET_COLOR = os.path.expanduser("~/.claude/tab-color/engine/set-color.sh")
ENV = {**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"}
LOG_FILE = os.path.expanduser("~/.claude/logs/focus-monitor-py.log")


def _log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def _kill_flash(tty_name):
    pid_file = f"/tmp/tab-flash-{tty_name}.pid"
    if not os.path.exists(pid_file):
        return False
    try:
        with open(pid_file) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
    except Exception:
        pass
    try:
        os.remove(pid_file)
    except OSError:
        pass
    return True


def _restore_active(tty, tty_name):
    """waiting/attention → active 색상 복원"""
    state_file = os.path.join(STATE_DIR, f"{tty_name}.json")
    if not os.path.exists(state_file):
        return
    try:
        with open(state_file) as f:
            data = json.load(f)
    except Exception:
        return
    state = data.get("type", "")
    if state not in ("waiting", "attention"):
        return
    project = data.get("project", "")
    env = {**ENV, "TAB_TTY": tty}
    subprocess.run(["bash", SET_COLOR, "active", project], env=env, check=False)
    _log(f"{state} → active ({project}, {tty_name})")


async def main(connection):
    app = await iterm2.async_get_app(connection)
    _log("=== FocusMonitor 시작 (색상 복원 활성) ===")

    async with iterm2.FocusMonitor(connection) as monitor:
        while True:
            update = await monitor.async_get_next_update()
            if not update.active_session_changed:
                continue
            session_id = update.active_session_changed.session_id
            session = app.get_session_by_id(session_id)
            if session is None:
                continue
            try:
                tty = await session.async_get_variable("tty")
                if tty:
                    tty_name = tty.replace("/dev/", "")
                    _kill_flash(tty_name)
                    _restore_active(tty, tty_name)
                # 배지 클리어
                await session.async_set_variable("user.badge", "")
            except Exception:
                pass


iterm2.run_forever(main)
