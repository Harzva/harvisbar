#!/usr/bin/env python3
"""Install the independent local version adapter; does not replace HarvisBar."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT=Path(__file__).resolve().parents[1]
FILES=['scripts/harvis_versions.py','scripts/harvis_version_agent.py','scripts/harvis_version_catalog.py',
       'mcp/harvis_versions_mcp.py','schemas/version-agent-v1.schema.json','schemas/version-catalog-v1.schema.json',
       'skills/harvis-versions/SKILL.md','skills/harvis-versions/agents/openai.yaml']

def sha(data):return hashlib.sha256(data).hexdigest()

def install(home):
    root=home/'.harvis/version-agent';releases=root/'releases'
    records={file:sha((ROOT/file).read_bytes()) for file in FILES}
    release_id=sha(json.dumps(records,sort_keys=True).encode())[:20]
    release=releases/release_id
    releases.mkdir(parents=True,exist_ok=True)
    if not release.exists():
        stage=Path(tempfile.mkdtemp(prefix='.stage-',dir=releases))
        try:
            for file in FILES:
                target=stage/file;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(ROOT/file,target)
            (stage/'release.json').write_text(json.dumps({'version':'1.0.0','releaseId':release_id,'files':records},indent=2)+'\n')
            stage.rename(release)
        finally:
            if stage.exists():shutil.rmtree(stage)
    for file,expected in records.items():
        if sha((release/file).read_bytes())!=expected:raise RuntimeError('Existing release content mismatch')
    launcher=home/'.local/bin/harvis-versions'
    skill=home/'.agents/skills/harvis-versions'
    expected_skill=root/'current/skills/harvis-versions'
    if skill.exists() or skill.is_symlink():
        if not skill.is_symlink() or Path(os.readlink(skill))!=expected_skill:
            raise RuntimeError('An unrelated skill exists; it was preserved')
    current=root/'current'
    if current.exists() and not current.is_symlink():raise RuntimeError('current is not a symlink')
    previous=os.readlink(current) if current.is_symlink() else None
    backup=None
    if launcher.exists():
        backups=root/'backups';backups.mkdir(exist_ok=True)
        backup=backups/('harvis-versions-'+uuid.uuid4().hex)
        shutil.copyfile(launcher,backup)
    temp_link=root/('.current-'+uuid.uuid4().hex)
    temp_link.symlink_to(release)
    os.replace(temp_link,current)
    try:
        launcher.parent.mkdir(parents=True,exist_ok=True)
        body='#!/bin/sh\nexec /usr/bin/python3 -I "$HOME/.harvis/version-agent/current/scripts/harvis_versions.py" "$@"\n'
        temp=launcher.with_name('.harvis-versions-'+uuid.uuid4().hex)
        temp.write_text(body);temp.chmod(0o755);os.replace(temp,launcher)
        result=subprocess.run(['/usr/bin/python3','-I',str(release/'scripts/harvis_versions.py'),'agent','capabilities'],check=True,capture_output=True,text=True)
        if not json.loads(result.stdout)['ok']:raise RuntimeError('Installed adapter failed')
        skill.parent.mkdir(parents=True,exist_ok=True)
        if not skill.is_symlink():skill.symlink_to(expected_skill)
    except Exception:
        if backup:shutil.copyfile(backup,launcher);launcher.chmod(0o755)
        elif launcher.exists():launcher.unlink()
        if previous:
            rollback=root/('.restore-'+uuid.uuid4().hex);rollback.symlink_to(previous);os.replace(rollback,current)
        elif current.is_symlink():current.unlink()
        raise
    receipt={'releaseId':release_id,'current':str(release),'previous':previous,'launcherBackup':str(backup) if backup else None,
             'skill':str(skill),'mcpCommand':[str(launcher),'mcp'],'files':records}
    receipt_file=root/('install-'+uuid.uuid4().hex+'.json');receipt_file.write_text(json.dumps(receipt,indent=2)+'\n');receipt_file.chmod(0o600)
    return receipt

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install',action='store_true',help='Install immutable release and switch only the agent CLI/skill pointer.')
    args=parser.parse_args()
    if not args.install:
        print('Preview: install a stdlib adapter under ~/.harvis/version-agent; preserve old CLI; link ~/.agents/skills/harvis-versions. Use --install to apply. No app or MCP config is changed.')
        return 0
    print(json.dumps(install(Path.home()),ensure_ascii=False,indent=2))
    return 0

if __name__=='__main__':raise SystemExit(main())
