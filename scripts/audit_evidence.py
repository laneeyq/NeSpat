#!/usr/bin/python3 -B
"""Fail-fast unique audit directory and exclusive logs; no privileged operations."""
from pathlib import Path
import datetime,json,os,subprocess,tempfile,sys
class Evidence:
    def __init__(self,path):
        self.path=Path(path)
        self.fd=os.open(self.path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    @classmethod
    def create(cls,parent,prefix):
        if not prefix or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in prefix):raise ValueError('Invalid prefix')
        # mkdtemp guarantees exclusive creation; any failure propagates before any subsequent action.
        return cls(tempfile.mkdtemp(prefix=prefix+'-',dir=parent))
    def _open(self,name):
        if not name or Path(name).name!=name or name in ['.','..']:raise ValueError('Flat log name required')
        return os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=self.fd)
    def write(self,name,data):
        with os.fdopen(self._open(name),'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    def run(self,label,args,cwd):
        # Reserve before running: a duplicate label refuses without repeating the command.
        with os.fdopen(self._open(label+'.json'),'w') as f:
            result={'argv':args,'cwd':str(cwd),'started_UTC':datetime.datetime.now(datetime.timezone.utc).isoformat()}
            try:
                p=subprocess.run(args,cwd=cwd,capture_output=True,text=True,env=dict(os.environ,GIT_OPTIONAL_LOCKS='0'))
                result.update(exit_code=p.returncode,stdout=p.stdout,stderr=p.stderr)
            except BaseException as error:
                result.update(exit_code=None,error=type(error).__name__+': '+str(error));raise
            finally:
                result['ended_UTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();json.dump(result,f,indent=2);f.flush();os.fsync(f.fileno())
        return p
    def close(self):os.close(self.fd)
if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: audit_evidence.py EXISTING_PARENT PREFIX')
    e=Evidence.create(sys.argv[1],sys.argv[2]);print(e.path);e.close()
