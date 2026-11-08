#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export JOY_SMOKE_ROOT="$PWD"
export FLUTTER_ENGINE_SWITCHES=2
export FLUTTER_ENGINE_SWITCH_1=enable-impeller=false
export FLUTTER_ENGINE_SWITCH_2=enable-software-rendering
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1

xvfb-run -a -s '-screen 0 1280x900x24 -nolisten tcp' python - <<'PY'
import os
from pathlib import Path
import json
import sqlite3
import subprocess
import tempfile
import time

from PIL import ImageGrab, ImageStat

root = Path(os.environ['JOY_SMOKE_ROOT'])
output = root / 'artifacts/screenshots'
output.mkdir(parents=True, exist_ok=True)

def visible_window(app, env):
    for _ in range(60):
        time.sleep(.25)
        result = subprocess.run([
            'xdotool', 'search', '--onlyvisible', '--pid', str(app.pid),
        ], env=env, capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.splitlines()[-1]
        if app.poll() is not None:
            break
    raise RuntimeError(f'No visible native frame within 15 seconds; process exit={app.poll()}.')

def count_capture(state, title):
    databases = list(Path(state).rglob('joy.sqlite'))
    if not databases:
        return 0
    with sqlite3.connect(databases[0]) as database:
        rows = database.execute('SELECT body FROM records').fetchall()
    return sum(json.loads(row[0])['title'] == title for row in rows)

with tempfile.TemporaryDirectory(prefix='joy-native-smoke-') as state:
    env = dict(os.environ, XDG_DATA_HOME=state, XDG_CACHE_HOME=state)
    with (output / 'linux-smoke.log').open('w') as log:
        app = subprocess.Popen([
            str(root / 'apps/joy/build/linux/x64/debug/bundle/joy'),
        ], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            window = visible_window(app, env)
            subprocess.run(['xdotool', 'windowsize', window, '1200', '820'], env=env, check=True)
            subprocess.run(['xdotool', 'windowmove', window, '30', '20'], env=env, check=True)
            time.sleep(1)
            image = ImageGrab.grab(xdisplay=env['DISPLAY'])
            if max(ImageStat.Stat(image).mean) < 20:
                raise SystemExit('Native frame is black; screenshot acceptance failed.')
            image.save(output / 'desktop-inbox.png')

            title = 'Native capture QA'
            if count_capture(state, title) != 0:
                raise RuntimeError('The smoke workspace is not isolated.')
            subprocess.run(['xdotool', 'windowfocus', '--sync', window], env=env, check=True)
            subprocess.run(['xdotool', 'mousemove', '--window', window, '620', '224', 'click', '1'], env=env, check=True)
            time.sleep(.4)
            subprocess.run(['xdotool', 'type', '--clearmodifiers', '--delay', '5', title], env=env, check=True)
            time.sleep(.2)
            ImageGrab.grab(xdisplay=env['DISPLAY']).save(output / 'desktop-compose.png')
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Return'], env=env, check=True)
            for _ in range(20):
                if count_capture(state, title) == 1:
                    break
                time.sleep(.1)
            if count_capture(state, title) != 1:
                ImageGrab.grab(xdisplay=env['DISPLAY']).save(output / 'desktop-after-enter.png')
                with sqlite3.connect(next(Path(state).rglob('joy.sqlite'))) as database:
                    print([json.loads(row[0])['title'] for row in database.execute('SELECT body FROM records')], flush=True)
                raise RuntimeError('Enter capture did not persist exactly one task.')
            app.terminate()
            app.wait(timeout=5)
            app = subprocess.Popen([
                str(root / 'apps/joy/build/linux/x64/debug/bundle/joy'),
            ], env=env, stdout=log, stderr=subprocess.STDOUT)
            window = visible_window(app, env)
            subprocess.run(['xdotool', 'windowsize', window, '1200', '820'], env=env, check=True)
            subprocess.run(['xdotool', 'windowmove', window, '30', '20'], env=env, check=True)
            time.sleep(1)
            if count_capture(state, title) != 1:
                raise RuntimeError('Capture did not survive the native application restart.')
            ImageGrab.grab(xdisplay=env['DISPLAY']).save(output / 'desktop-capture-restart.png')
            subprocess.run(['xdotool', 'windowsize', window, '430', '820'], env=env, check=True)
            time.sleep(1)
            ImageGrab.grab(xdisplay=env['DISPLAY']).save(output / 'desktop-narrow-inbox.png')
            print('Native desktop and narrow frames rendered; Enter captured exactly one SQLite task and restart preserved it. Screenshots saved.')
        finally:
            if app.poll() is None:
                app.terminate()
                app.wait(timeout=5)
PY
