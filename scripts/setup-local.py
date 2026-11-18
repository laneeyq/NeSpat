#!/usr/bin/python3 -I
"""Explicitly approved one-time LOCAL setup. NEVER invoked by build/tests/GUI automatically."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

BASE = Path('/Library/Application Support/NeSpatPrivileged')
LABEL = 'local.nespat.privilege-helper'

def main():
    if os.geteuid() != 0:
        print('Root setup requires separate explicit approval; no changes made.', file=sys.stderr)
        return 77
    if len(sys.argv) == 3 and sys.argv[1] in ('--approve-power-enable','--approve-power-disable'):
        file=BASE/'LocalTrust/profile.json'
        profile=json.loads(file.read_text())
        if profile['setup'] != sys.argv[2] or file.stat().st_uid != 0 or file.stat().st_mode & 0o022:raise RuntimeError('Setup identity mismatch')
        enabling = sys.argv[1] == '--approve-power-enable'
        if enabling: subprocess.run([str(BASE/'NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper'),'--check-local'],check=True)
        profile['enabled']=enabling
        candidate=BASE/'LocalTrust/profile.next'
        with candidate.open('x') as f:
            json.dump(profile,f,sort_keys=True);f.flush();os.fsync(f.fileno())
        os.chmod(candidate,0o644);os.replace(candidate,file)
        fd=os.open(str(file.parent),os.O_RDONLY);os.fsync(fd);os.close(fd)
        print('Power activation permission:',enabling,'; installer issued no power command.')
        return 0
    if len(sys.argv) != 4 or sys.argv[1] != '--approve-local-automatic-mode':
        print('Required: --approve-local-automatic-mode ABSOLUTE_ZIP REVIEWED_SHA256', file=sys.stderr)
        return 64
    source, digest = Path(sys.argv[2]), sys.argv[3]
    if not source.is_absolute() or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
        return 64
    if BASE.exists() or Path('/Library/LaunchDaemons/'+LABEL+'.plist').exists() or Path('/Library/LaunchAgents/local.nespat.gui.plist').exists():
        print('Existing installation/state preserved. Review migration separately.', file=sys.stderr)
        return 73
    # Copy before checking: caller cannot change bytes between validation and extraction.
    stage = Path(tempfile.mkdtemp(prefix='nespat-reviewed-', dir='/private/var/tmp'))
    os.chmod(stage, 0o700)
    package = stage/'package.zip';shutil.copyfile(source,package);os.chmod(package,0o600)
    if hashlib.sha256(package.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Reviewed artifact hash mismatch; staged bytes retained for review')
    with zipfile.ZipFile(package) as z:
        if z.testzip() is not None or len(z.namelist()) != len(set(z.namelist())):raise RuntimeError('Invalid ZIP')
        for i in z.infolist():
            name=PurePosixPath(i.filename)
            if name.is_absolute() or '..' in name.parts or (i.filename!='profile.json' and name.parts[0]!='NeSpat.app') or str(name)!=i.filename or stat.S_ISLNK(i.external_attr>>16):raise RuntimeError('Unsafe ZIP entry')
            p=stage/i.filename;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(z.read(i));os.chmod(p,(i.external_attr>>16)&0o755 or 0o644)
    profile=json.loads((stage/'profile.json').read_text())
    if profile.get('version')!=1 or not isinstance(profile.get('allowedUID'),int) or profile['allowedUID']<=0 or profile.get('enabled') is not False:raise RuntimeError('Invalid approved profile')
    app=stage/'NeSpat.app'
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    for target,key,identifier in [(app,'guiHash','local.nespat.app'),(app/'Contents/Library/Helpers/NeSpatPrivilegeHelper','helperHash',LABEL)]:
        r=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(target)],capture_output=True,text=True,check=True)
        pin = profile[key]
        if not isinstance(pin, str) or not re.fullmatch('[a-f0-9]{40}', pin):
            raise RuntimeError('Invalid code directory hash')
        requirement = f'=identifier "{identifier}" and cdhash H"{pin}"'
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, str(target)], check=True)
        if not re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\((?:[^()]*,)?runtime(?:,[^()]*)?\)', r.stderr, re.M):
            raise RuntimeError('Hardened runtime required')
    # No existing apps removed. Provision only new root-owned immutable-by-client paths.
    BASE.mkdir(mode=0o755)
    (BASE/'State').mkdir(mode=0o700);(BASE/'LocalTrust').mkdir(mode=0o755)
    shutil.copytree(app,BASE/'NeSpat.app',copy_function=shutil.copy2)
    for root,dirs,files in os.walk(BASE):
        os.chown(root,0,0);os.chmod(root,0o700 if Path(root)==BASE/'State' else 0o755)
        for name in files:
            p=Path(root)/name;os.chown(p,0,0);os.chmod(p,p.stat().st_mode&0o755)
    shutil.copyfile(stage/'profile.json',BASE/'LocalTrust/profile.json');os.chown(BASE/'LocalTrust/profile.json',0,0);os.chmod(BASE/'LocalTrust/profile.json',0o644)
    import plistlib
    plist=Path('/Library/LaunchDaemons/'+LABEL+'.plist')
    helper=str(BASE/'NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper')
    plist.write_bytes(plistlib.dumps({'Label':LABEL,'ProgramArguments':[helper,'--serve-local'],'MachServices':{LABEL:True},'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':30,'ProcessType':'Background'}))
    os.chown(plist,0,0);os.chmod(plist,0o644)
    agent=Path('/Library/LaunchAgents/local.nespat.gui.plist')
    agent.write_bytes(plistlib.dumps({'Label':'local.nespat.gui','ProgramArguments':[str(BASE/'NeSpat.app/Contents/MacOS/NeSpat'),'--auto-agent'],'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'LimitLoadToSessionType':'Aqua','ThrottleInterval':30}))
    os.chown(agent,0,0);os.chmod(agent,0o644)
    subprocess.run(['/bin/launchctl','bootstrap','system',str(plist)],check=True)
    print('Local service installed in POWER-DISABLED mode. Run reviewed read-only preflight first; enabling power requires separate approval.')
    print('Staging retained:',stage)
    return 0

if __name__ == '__main__':sys.exit(main())
