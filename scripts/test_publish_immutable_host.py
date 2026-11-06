"""Run the real publisher in a sandbox; an existing release must never be replaced."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tumo-publish-contract-') as directory:
    work = Path(directory)
    (work / 'scripts').mkdir()
    (work / 'bin').mkdir()
    shutil.copy2(ROOT / 'scripts/publish.sh', work / 'scripts/publish.sh')
    (work / 'project.yml').write_text('settings:\n  base:\n    MARKETING_VERSION: "99.0.1"\n')
    (work / 'apps.json').write_text('{"apps":[{"versions":[]}]}')
    builder = work / 'scripts/build_ipa.sh'
    builder.write_text('''#!/bin/bash
python3 - <<'BUILD'
import pathlib, plistlib, zipfile
pathlib.Path('build').mkdir(exist_ok=True)
with zipfile.ZipFile('build/TumoCompanion-unsigned.ipa','w') as archive:
    archive.writestr('Payload/UnleashedCompanion.app/Info.plist', plistlib.dumps({
        'CFBundlePackageType':'APPL','CFBundleShortVersionString':'99.0.1'}))
BUILD
''')
    fake_git = work / 'bin/git'
    fake_git.write_text('''#!/bin/bash
case "$*" in
  *"status --porcelain"*) exit 0;;
  *"branch --show-current"*) echo main;;
  *"rev-parse"*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;;
esac
exit 0
''')
    fake_gh = work / 'bin/gh'
    fake_gh.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$TUMO_PUBLISH_TEST_LOG"
case "$*" in
  "release view "*)
    if [[ "$*" == *"--json assets"* ]]; then echo TumoCompanion-unsigned.ipa; fi
    exit 0;;
esac
exit 0
''')
    for executable in (builder, fake_git, fake_gh):
        executable.chmod(0o755)
    log = work / 'gh.log'
    result = subprocess.run(['bash', str(work / 'scripts/publish.sh'), 'sandbox test'], cwd=work,
        env={**os.environ, 'PATH': str(work / 'bin') + ':' + os.environ['PATH'],
             'TUMO_PUBLISH_TEST_LOG': str(log)}, text=True, capture_output=True)
    calls = log.read_text() if log.exists() else ''
    writes = [line for line in calls.splitlines()
              if line.startswith(('release upload ', 'release create '))]
    if 'release view v99.0.1 ' not in calls:
        raise SystemExit('FAIL: sandbox did not reach the existing-release guard')
    if result.returncode == 0 or writes:
        raise SystemExit('FAIL: publisher accepted/replaced an existing release: ' + repr(writes))
    print('PASS: real publisher aborts for an existing release without upload/create or Feather changes')
