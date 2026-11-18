#!/usr/bin/python3 -IB
"""Local, user-initiated setup. Copy reviewed inputs before requesting macOS authorization."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

REVIEWED_SHA256 = None  # Populated by build-local.sh before distribution.

# Executed with the system interpreter in isolated mode. All imports and executable code
# beyond the standard library come from hash-verified, private root-owned staging.
DRIVER = '''
import hashlib,os,sys,runpy,stat,tempfile
from pathlib import Path
source=Path(sys.argv[1])
mode=sys.argv[2]
hashes=sys.argv[3:]
names=['exclusive-install.py','acceptance-install.py','local-setup.zip']
if len(hashes)!=len(names) or os.geteuid()!=0:raise SystemExit(77)
with tempfile.TemporaryDirectory(prefix='nespat-local-',dir='/private/var/tmp') as tmp:
    stage=Path(tmp)
    source_fd=os.open(source,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    for name,digest in zip(names,hashes):
        limit=100_000_000 if name.endswith('.zip') else 256_000
        fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=source_fd)
        with os.fdopen(fd,'rb') as f:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or not 0<info.st_size<=limit:
                raise ValueError('Unexpected input type or size')
            data=f.read(info.st_size+1)
            if len(data)!=info.st_size:raise ValueError('Input size changed')
        if hashlib.sha256(data).hexdigest()!=digest:raise ValueError('Input changed: '+name)
        (stage/name).write_bytes(data)
    os.close(source_fd)
    common=runpy.run_path(str(stage/names[1]))
    files,manifest,profile=common['package']((stage/names[2]).read_bytes(),hashes[2],mode='exclusive')
    for name,data in files.items():
        output=stage/name
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_bytes(data)
        output.chmod(manifest['files'][name]['mode'])
    sys.argv=[str(stage/names[0]),mode,str(stage/names[2]),hashes[2],str(stage)]
    runpy.run_path(sys.argv[0],run_name='__main__')
'''
def main():
    if os.geteuid()==0 or len(sys.argv)!=2 or sys.argv[1] not in {'install-disabled','approve-single-trial','approve-production','rollback'}:
        raise SystemExit('Run as the signed-in user with one setup operation')
    bundle=Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix='nespat-inputs-',dir='/private/tmp') as tmp:
        names=['exclusive-install.py','acceptance-install.py','local-setup.zip']
        hashes=[]
        for name in names:
            target=Path(tmp)/name
            shutil.copyfile(bundle/name,target)
            hashes.append(hashlib.sha256(target.read_bytes()).hexdigest())
        if REVIEWED_SHA256 != dict(zip(names,hashes)):
            raise SystemExit('Состав установщика изменился. Распакуйте проверенный архив заново.')
        command=shlex.join(['/usr/bin/python3','-IB','-c',DRIVER,tmp,sys.argv[1],*hashes])
        script='on run argv\nwith timeout of 300 seconds\nreturn do shell script (item 1 of argv) with administrator privileges\nend timeout\nend run'
        subprocess.run(['/usr/bin/osascript','-e',script,command],cwd='/',check=True)
if __name__=='__main__':main()
