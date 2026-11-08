#!/usr/bin/env bash
set -euo pipefail

JOY_LINUX_PREFIX="${1:-/workspace/.toolchains/local-linux}"
export JOY_LINUX_PREFIX
python - <<'PY'
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess

base = Path(os.environ['JOY_LINUX_PREFIX']).resolve()
apt = base / 'apt'
prefix = base / 'root'
os_info = Path('/etc/os-release').read_text()
if 'VERSION_CODENAME=trixie' not in os_info:
    raise SystemExit('This user-prefix installer targets Debian 13. Use your system package manager on other distributions.')
for name in ['lists/partial', 'archives/partial', 'empty', 'cache']:
    (apt / name).mkdir(parents=True, exist_ok=True)
keyring = '/usr/share/keyrings/debian-archive-keyring.gpg'
(apt / 'sources.list').write_text('\n'.join([
    f'deb [signed-by={keyring}] https://deb.debian.org/debian trixie main',
    f'deb [signed-by={keyring}] https://deb.debian.org/debian trixie-updates main',
    f'deb [signed-by={keyring}] https://security.debian.org/debian-security trixie-security main',
    '',
]))
(apt / 'apt.conf').write_text('\n'.join([
    'Dir::Etc::main "-";',
    f'Dir::Etc::parts "{apt}/empty";',
    f'Dir::Etc::sourcelist "{apt}/sources.list";',
    f'Dir::Etc::sourceparts "{apt}/empty";',
    f'Dir::State::lists "{apt}/lists";',
    'Dir::State::status "/var/lib/dpkg/status";',
    f'Dir::Cache "{apt}/cache";',
    f'Dir::Cache::archives "{apt}/archives";',
    '',
]))
env = dict(os.environ, APT_CONFIG=str(apt / 'apt.conf'))
subprocess.run(['/usr/bin/apt-get', 'update'], env=env, check=True)
targets = ['clang', 'cmake', 'ninja-build', 'libgtk-3-dev', 'xvfb', 'xauth', 'xdotool', 'openjdk-21-jdk-headless']
plan = subprocess.check_output([
    '/usr/bin/apt-get', '-s', '--no-install-recommends', 'install', *targets,
], env=env, text=True)
(apt / 'plan.txt').write_text(plan)
packages = []
for line in plan.splitlines():
    if line.startswith('Inst '):
        version = re.search(r'\(([^ ]+)', line).group(1)
        packages.append(line.split()[1] + '=' + version)
jre_policy = subprocess.check_output(['/usr/bin/apt-cache', 'policy', 'openjdk-21-jre-headless'], env=env, text=True)
jre_version = re.search(r'Candidate:\s*(\S+)', jre_policy).group(1)
packages.append('openjdk-21-jre-headless=' + jre_version)
packages = list(dict.fromkeys(packages))
if packages:
    subprocess.run(['/usr/bin/apt-get', 'download', *packages], env=env, cwd=apt / 'archives', check=True)
prefix.mkdir(exist_ok=True)
manifest = {}
for deb in sorted((apt / 'archives').glob('*.deb')):
    subprocess.run(['dpkg-deb', '-x', str(deb), str(prefix)], check=True)
    with deb.open('rb') as stream:
        manifest[deb.name] = hashlib.file_digest(stream, 'sha256').hexdigest()
(base / 'packages.json').write_text(json.dumps(manifest, indent=2) + '\n')
for pc in (prefix / 'usr').rglob('*.pc'):
    text = pc.read_text().replace('prefix=/usr', f'prefix={prefix}/usr')
    for key in ['libdir', 'includedir', 'datadir']:
        text = text.replace(key + '=/usr/', key + f'={prefix}/usr/')
    pc.write_text(text)
for path in (prefix / 'usr/lib').rglob('*'):
    if path.is_symlink() and not path.exists():
        for directory in [Path('/usr/lib/x86_64-linux-gnu'), Path('/lib/x86_64-linux-gnu')]:
            target = directory / Path(os.readlink(path)).name
            if target.exists():
                path.unlink()
                path.symlink_to(target)
                break
env_file = base / 'env.sh'
env_file.write_text('\n'.join([
    f'export JAVA_HOME="{prefix}/usr/lib/jvm/java-21-openjdk-amd64"',
    f'export PATH="$JAVA_HOME/bin:{prefix}/usr/bin:{prefix}/usr/lib/llvm-19/bin:$PATH"',
    f'export LD_LIBRARY_PATH="{prefix}/usr/lib/x86_64-linux-gnu:{prefix}/usr/lib/llvm-19/lib:${{LD_LIBRARY_PATH:-}}"',
    f'export PKG_CONFIG_PATH="{prefix}/usr/lib/x86_64-linux-gnu/pkgconfig:{prefix}/usr/share/pkgconfig:${{PKG_CONFIG_PATH:-}}"',
    '',
]))
print(f'Linux dependencies installed without system changes. Run: source {env_file}')
PY
