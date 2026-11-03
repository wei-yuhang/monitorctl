#!/usr/bin/env python3
"""Install the CLI, a global PATH entry, and local Codex discovery guidance."""
from pathlib import Path
from datetime import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

SOURCE=Path(__file__).resolve().parent
SUPPORT=Path.home()/'Library/Application Support/monitorctl'
APP=SUPPORT/'app'
LINK=Path('/usr/local/bin/monitorctl')
SKILL=Path.home()/'.agents/skills/monitor-control'
GUIDE_ROOT=Path(os.environ.get('CODEX_HOME') or Path.home()/'.codex')
GUIDE=GUIDE_ROOT/('AGENTS.override.md' if (GUIDE_ROOT/'AGENTS.override.md').exists() else 'AGENTS.md')
STAMP=datetime.now().strftime('%Y%m%d-%H%M%S')

def run(args,**kw):
    return subprocess.run([str(x) for x in args],check=True,**kw)

pending=SUPPORT/'state/preview.json'
if pending.exists():
    raise SystemExit('Finish the active preview with monitorctl confirm/revert before updating the CLI.')
if LINK.exists() or LINK.is_symlink():
    if not LINK.is_symlink() or LINK.resolve()!=APP/'monitorctl':
        raise SystemExit('/usr/local/bin/monitorctl already belongs to another installation; left untouched.')
SUPPORT.mkdir(parents=True,exist_ok=True)
backup=SUPPORT/'backups'/STAMP
backup.mkdir(parents=True)
for path,label in [(APP,'app'),(SKILL,'skill'),(GUIDE,'global-agent-instructions')]:
    if path.is_symlink():
        raise SystemExit(f'Review existing symlink before replacing {path}')
    if path.is_dir():shutil.copytree(path,backup/label)
    elif path.is_file():shutil.copy2(path,backup/label)

stage=SUPPORT/('app.staging-'+STAMP)
shutil.copytree(SOURCE,stage,ignore=shutil.ignore_patterns('.git','__pycache__','.venv','.DS_Store','installation.json'))
(stage/'monitorctl').chmod(0o755)
previous=SUPPORT/('app.previous-'+STAMP)
if APP.exists():APP.rename(previous)
stage.rename(APP)

try:
    # Only creating the PATH entry needs administrator authentication.
    if not LINK.is_symlink():
        with tempfile.TemporaryDirectory(prefix='monitorctl-install-',dir='/private/tmp') as tmp:
            helper=Path(tmp)/'link.py'
            helper.write_text('''from pathlib import Path
import sys
source=Path(sys.argv[1])
link=Path('/usr/local/bin/monitorctl')
if not source.is_file():raise SystemExit('Installed executable is missing')
if link.exists() or link.is_symlink():
 if not link.is_symlink() or link.resolve()!=source:raise SystemExit('Existing command left untouched')
else:
 link.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
 link.symlink_to(source)
print('Installed /usr/local/bin/monitorctl')
''')
            import shlex
            command=shlex.join(['/usr/bin/python3',str(helper),str(APP/'monitorctl')])
            script='do shell script '+json.dumps(command)+' with administrator privileges'
            run(['/usr/bin/osascript','-e',script])
    SKILL.parent.mkdir(parents=True,exist_ok=True)
    if SKILL.exists():shutil.rmtree(SKILL)
    shutil.copytree(APP/'skill',SKILL)
    GUIDE_ROOT.mkdir(parents=True,exist_ok=True)
    begin='<!-- monitorctl:start -->'
    end='<!-- monitorctl:end -->'
    block=f'''{begin}
## Local monitor control

For requests to change this Mac's monitor text size, HiDPI scaling, resolution,
or refresh rate, use `/usr/local/bin/monitorctl` rather than creating new
monitor-specific scripts. Read `{SKILL / 'SKILL.md'}` for the workflow.
The complete installed source is in `{APP}`. This applies to local monitor
tasks and does not change unrelated project workflows.
{end}'''
    existing=GUIDE.read_text() if GUIDE.exists() else ''
    if begin in existing:
        prefix,tail=existing.split(begin,1)
        if end not in tail:raise RuntimeError('Existing monitorctl discovery block is incomplete')
        _,suffix=tail.split(end,1)
        contents=prefix+block+suffix
    else:
        contents=existing.rstrip()+('\n\n' if existing.strip() else '')+block+'\n'
    GUIDE.write_text(contents)
    listed=json.loads(subprocess.check_output([str(LINK),'list','--json'],text=True))
    assert listed['ok'] and listed['displays']
    report={'result':'installed','command':str(LINK),'runtime':str(APP),
            'skill':str(SKILL),'global_discovery':str(GUIDE),'backup':str(backup),
            'current_displays':listed['displays']}
    (SOURCE/'installation.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))
except BaseException:
    if APP.exists():shutil.rmtree(APP)
    if previous.exists():previous.rename(APP)
    if LINK.is_symlink() and not LINK.exists():
        print('The PATH entry can be removed with sudo rm /usr/local/bin/monitorctl.',file=sys.stderr)
    if (backup/'skill').exists():
        if SKILL.exists():shutil.rmtree(SKILL)
        shutil.copytree(backup/'skill',SKILL)
    if (backup/'global-agent-instructions').exists():
        shutil.copy2(backup/'global-agent-instructions',GUIDE)
    raise
