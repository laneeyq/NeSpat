#!/usr/bin/python3 -I
"""Acceptance-only transaction. Importable rootless harness; CLI never installs implicitly."""
import ctypes
import contextlib
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import sys
import uuid
import zipfile
import io

BASE = Path('/Library/Application Support/NeSpatPrivileged')
PLIST = Path('/Library/LaunchDaemons/local.nespat.privilege-helper.plist')
LABEL = 'local.nespat.privilege-helper'
JOURNAL = BASE.parent / '.NeSpatAcceptanceTransaction.json'
SHA = lambda b: hashlib.sha256(b).hexdigest()
class Stop(RuntimeError): pass

def syncdir(p):
    fd=os.open(p,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)

def secure(p, uid=0, directory=True):
    s=p.lstat()
    if stat.S_ISLNK(s.st_mode) or s.st_uid!=uid or s.st_mode&0o022 or (directory and not stat.S_ISDIR(s.st_mode)) or (not directory and (not stat.S_ISREG(s.st_mode) or s.st_nlink!=1)):
        raise Stop('Unsafe path: '+str(p))
    # macOS ACLs are a separate permission channel; unknown errors are STOP.
    if sys.platform=='darwin':
        r=subprocess.run(['/bin/ls','-lde',str(p)],capture_output=True,text=True,check=True)
        if len(r.stdout.splitlines())!=1: raise Stop('ACL present/unknown: '+str(p))

def package(data, digest, *, mode="acceptance-only"):
    if SHA(data)!=digest: raise Stop('ZIP hash mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        if z.testzip() or len(set(z.namelist()))!=len(z.namelist()): raise Stop('ZIP integrity')
        files={}
        for i in z.infolist():
            n=PurePosixPath(i.filename)
            if n.is_absolute() or '..' in n.parts or str(n)!=i.filename or i.is_dir() or stat.S_ISLNK(i.external_attr>>16) or i.file_size>100_000_000: raise Stop('ZIP path/type')
            files[i.filename]=z.read(i)
    manifest=json.loads(files.pop('acceptance-manifest.json'))
    if set(files)!=set(manifest['files']) or manifest['mode']!=mode: raise Stop('Manifest mismatch')
    for n,b in files.items():
        if not (n=='profile.json' or n.startswith('NeSpat.app/')) or SHA(b)!=manifest['files'][n]['sha256']: raise Stop('File mismatch')
    profile=json.loads(files['profile.json'])
    if profile.get('enabled') is not False: raise Stop('Package must start disabled')
    if mode == 'acceptance-only':
        if profile.get('acceptanceOnly') is not True: raise Stop('Not inert acceptance profile')
    elif mode == 'exclusive':
        if profile.get('exclusiveControl') is not True or profile.get('acceptanceOnly') is not None or type(profile.get('trialOnly')) is not bool:
            raise Stop('Invalid exclusive-control package')
    else: raise Stop('Unknown installation mode')
    if profile.get('version')!=1 or type(profile.get('allowedUID')) is not int or profile['allowedUID']<=0: raise Stop('Invalid UID/profile')
    uuid.UUID(profile['setup'])
    expected={'NeSpat.app/Contents/_CodeSignature/CodeResources','NeSpat.app/Contents/Info.plist','NeSpat.app/Contents/MacOS/NeSpat','NeSpat.app/Contents/Resources/AppIcon.icns','NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper','profile.json'}
    if set(files)!=expected: raise Stop('Unexpected package files')
    for n,v in manifest['files'].items():
        expected_mode=0o755 if n in ['NeSpat.app/Contents/MacOS/NeSpat','NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper'] else 0o644
        if v['mode']!=expected_mode: raise Stop('Invalid file mode')
    return files,manifest,profile

def checked_run(args):
    return subprocess.run(args,capture_output=True,text=True,check=True)

def signatures(app, profile):
    checked_run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)])
    for p,k,identifier in [(app,'guiHash','local.nespat.app'),(app/'Contents/Library/Helpers/NeSpatPrivilegeHelper','helperHash',LABEL)]:
        text=checked_run(['/usr/bin/codesign','-d','--verbose=4',str(p)]).stderr
        lines=text.splitlines()
        if 'CDHash='+profile[k] not in lines or 'Identifier='+identifier not in lines or not any('runtime' in l and 'flags=' in l for l in lines): raise Stop('Pin/runtime mismatch')
        ent=checked_run(['/usr/bin/codesign','-d','--entitlements',':-',str(p)]).stdout
        if ent.strip():
            d=plistlib.loads(ent.encode())
            if any(d.get(k) for k in ['com.apple.security.get-task-allow','com.apple.security.cs.disable-library-validation','com.apple.security.cs.allow-dyld-environment-variables','com.apple.security.cs.allow-unsigned-executable-memory']): raise Stop('Unsafe entitlement')

def legacy_no_acl(fd,directory=False):
    lib=ctypes.CDLL(None,use_errno=True)
    get=lib.acl_get_fd_np;get.argtypes=[ctypes.c_int,ctypes.c_int];get.restype=ctypes.c_void_p
    free=lib.acl_free;free.argtypes=[ctypes.c_void_p]
    ctypes.set_errno(0);ptr=get(fd,0x100) # SDK ACL_TYPE_EXTENDED
    error=ctypes.get_errno()
    if not ptr:
        if error!=errno.ENOENT:raise Stop('Legacy journal ACL unknown')
        return
    try:
        # macOS homes/Library commonly carry restrictive deny-delete entries.
        # DENY entries cannot add permissions; file/lock ACLs and any directory ALLOW remain STOP.
        if not directory:raise Stop('Legacy journal ACL present')
        valid=lib.acl_valid;valid.argtypes=[ctypes.c_void_p]
        if valid(ptr)!=0:raise Stop('Invalid legacy directory ACL')
        entry=lib.acl_get_entry;entry.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_void_p)]
        tag=lib.acl_get_tag_type;tag.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint)]
        for index in range(170): # SDK maximum169; index retrieval is the documented Darwin extension.
            value=ctypes.c_void_p();ctypes.set_errno(0)
            if entry(ptr,index,ctypes.byref(value))!=0:
                if index>0 and ctypes.get_errno()==errno.EINVAL:return
                raise Stop('Legacy ACL enumeration unknown')
            kind=ctypes.c_uint()
            if tag(value,ctypes.byref(kind))!=0 or kind.value!=2:raise Stop('Legacy directory ACL grants/unknown')
        raise Stop('Legacy ACL size unknown')
    finally:free(ptr)

def legacy_metadata(fd,uid,directory=False):
    s=os.fstat(fd)
    if directory:
        okay=stat.S_ISDIR(s.st_mode) and s.st_uid in [0,uid] and not s.st_mode&0o022
    else:
        okay=stat.S_ISREG(s.st_mode) and s.st_uid==uid and s.st_nlink==1 and stat.S_IMODE(s.st_mode)==0o600
    if not okay:raise Stop('Legacy owner/type/permissions/link mismatch')
    legacy_no_acl(fd,directory)
    return (s.st_dev,s.st_ino,s.st_uid,s.st_gid,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

def legacy_ended_bytes(raw):
    def pairs(items):
        result={}
        for key,value in items:
            if key in result:raise Stop('Duplicate legacy field')
            result[key]=value
        return result
    def bad_constant(_):raise Stop('Nonfinite legacy JSON')
    try:data=json.loads(raw,object_pairs_hook=pairs,parse_constant=bad_constant)
    except (ValueError,UnicodeDecodeError) as error:raise Stop('Damaged legacy JSON') from error
    # Exact identity-bearing ended receipt emitted by current Session.ended().
    # Original four-field HEAD journal is deliberately NOT accepted: owned=false was fail-open there.
    keys={'owned','pid','owner','originalSleepDisabled','identifier','lastReason'}
    if type(data) is not dict or set(data)!=keys or data['owned'] is not False or data['originalSleepDisabled'] is not False:
        raise Stop('Unproven legacy ended format')
    def integer(v,low,high):return type(v) is int and low<=v<=high
    def identifier(v):
        if type(v) is not str or len(v)!=36:return False
        try:u=uuid.UUID(v);return u.int!=0 and str(u)==v.lower()
        except ValueError:return False
    owner=data['owner']
    if type(owner) is not dict or set(owner)!={'pid','executable','startSeconds','startMicroseconds','bootID'}:raise Stop('Incomplete legacy identity')
    if not integer(data['pid'],1,2147483647) or type(owner['pid']) is not int or owner['pid']!=data['pid']:
        raise Stop('Legacy PID mismatch')
    if not integer(owner['startSeconds'],1,18446744073709551615) or not integer(owner['startMicroseconds'],0,999999) or not identifier(owner['bootID']) or not identifier(data['identifier']):raise Stop('Legacy identity types invalid')
    path=owner['executable'];reason=data['lastReason']
    if type(path) is not str or not path.startswith('/') or '\0' in path or not path.endswith('/Contents/MacOS/NeSpat') or type(reason) is not str or not 1<=len(reason)<=4096:
        raise Stop('Legacy receipt types invalid')
    return data

def legacy_snapshot(home,uid,stack,locks):
    """Pinned no-follow descriptors, read-only existing lock; creates/deletes nothing."""
    key=str(home)
    try:
        with contextlib.ExitStack() as local:
            fd=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);local.callback(os.close,fd)
            bindings=[]
            for name in [None,'Library','Application Support','NeSpat']:
                if name is not None:
                    fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);local.callback(os.close,fd)
                meta=legacy_metadata(fd,uid,True);bindings.append(meta[:5])
            try:lock=os.open('session.lock',os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
            except FileNotFoundError:lock=None
            lock_meta=None
            if lock is not None:
                try:
                    lock_meta=legacy_metadata(lock,uid)
                    if key in locks:
                        if locks[key]!=lock_meta:raise Stop('Legacy lock changed')
                    else:
                        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                        locks[key]=lock_meta;stack.callback(os.close,lock);stack.callback(fcntl.flock,lock,fcntl.LOCK_UN);lock=None
                finally:
                    if lock is not None:os.close(lock)
            try:f=os.open('session.json',os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
            except FileNotFoundError:return (tuple(bindings),lock_meta,None)
            local.callback(os.close,f)
            before=legacy_metadata(f,uid)
            if lock_meta is None:raise Stop('Existing legacy receipt without lock')
            if before[6]>16384:raise Stop('Legacy receipt too large')
            raw=os.read(f,16385)
            if len(raw)!=before[6] or legacy_metadata(f,uid)!=before:raise Stop('Legacy journal changed during read')
            legacy_ended_bytes(raw)
            return (tuple(bindings),lock_meta,(before,SHA(raw)))
    except OSError as error:raise Stop('Legacy journal path/lock/read unknown: '+str(error)) from error

def legacy_scan(profile,stack,locks):
    secure(Path('/Users'))
    result={}
    for home in Path('/Users').iterdir():
        if home.is_symlink():raise Stop('Unknown home link')
        if home.is_dir():
            support=home/'Library/Application Support/NeSpat'
            if os.path.lexists(support):
                if home.lstat().st_uid!=profile['allowedUID']:raise Stop('Unsupported legacy owner')
                result[str(home)]=legacy_snapshot(home,profile['allowedUID'],stack,locks)
    return result

def quiescent_services(profile):
    for domain in ['system/'+LABEL,'gui/'+str(profile['allowedUID'])+'/local.nespat.gui','gui/'+str(profile['allowedUID'])+'/local.nespat.watchdog']:
        r=subprocess.run(['/bin/launchctl','print',domain],capture_output=True,text=True)
        if r.returncode!=113 or 'Could not find service' not in r.stderr:raise Stop('Service conflict/unknown: '+domain)
    # A helper launched outside launchd also blocks acceptance; names are fixed, not caller supplied.
    for name in ['NeSpat','NeSpatPrivilegeHelper','NeSpatAcceptanceHelper']:
        r=subprocess.run(['/usr/bin/pgrep','-x',name],capture_output=True,text=True)
        if r.returncode!=1:raise Stop('GUI/helper running or process state unknown')

def ordinary_sleep():
    raw=checked_run(['/usr/sbin/ioreg','-a','-r','-c','IOPMrootDomain']).stdout
    entries=plistlib.loads(raw.encode());values=[e['SleepDisabled'] for e in entries if 'SleepDisabled' in e]
    if len(values)!=1 or type(values[0]) is not bool or values[0] is not False:raise Stop('SleepDisabled not confirmed No')


def system_probe(artifact,profile):
    # Read-only, before creating any installation/transaction file. Never executes package code as root.
    for dest in [BASE,PLIST,Path('/Library/LaunchAgents/local.nespat.gui.plist')]:
        if os.path.lexists(dest): raise Stop('Existing destination: '+str(dest))
    for parent in [BASE.parent,PLIST.parent,Path('/Library/LaunchAgents')]:
        for p in [*reversed(parent.parents),parent]: secure(p)
    if os.path.lexists(JOURNAL):
        secure(JOURNAL,0,False)
        prior=json.loads(JOURNAL.read_text())
        if prior.get('version')!=1 or prior.get('mode')!='acceptance-only' or prior.get('phase')!='rolled-back':raise Stop('Prior transaction requires explicit resume/rollback')
        uuid.UUID(prior['id'])
    with contextlib.ExitStack() as stack:
        locks={}
        quiescent_services(profile)
        ordinary_sleep()
        initial=legacy_scan(profile,stack,locks)
        signatures(artifact/'NeSpat.app',profile)
        quiescent_services(profile)
        ordinary_sleep()
        if legacy_scan(profile,stack,locks)!=initial:raise Stop('Legacy journal changed between checks')
    if BASE.parent.stat().st_dev!=PLIST.parent.stat().st_dev:raise Stop('Cross-volume transaction unsupported')
    if not hasattr(ctypes.CDLL(None),'renamex_np'):raise Stop('Exclusive rename unavailable')
    # Parent/destination checks also define whether rollback can operate without following client links.
    return True

def fingerprint(path):
    s=path.lstat()
    if path.is_symlink(): raise Stop('Replacement link')
    if path.is_file(): return {'inode':s.st_ino,'device':s.st_dev,'sha':SHA(path.read_bytes()),'mode':stat.S_IMODE(s.st_mode)}
    files={}
    for p in sorted(path.rglob('*')):
        if p.is_symlink() or not (p.is_file() or p.is_dir()): raise Stop('Unexpected type')
        files[p.relative_to(path).as_posix()]=[stat.S_IMODE(p.stat().st_mode),SHA(p.read_bytes()) if p.is_file() else 'directory']
    return {'inode':s.st_ino,'device':s.st_dev,'tree':files,'mode':stat.S_IMODE(s.st_mode)}

def rename_exclusive(src,dst):
    # Darwin RENAME_EXCL prevents accidentally replacing a concurrently-created file or directory.
    libc=ctypes.CDLL(None,use_errno=True)
    fn=libc.renamex_np; fn.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
    if fn(os.fsencode(src),os.fsencode(dst),4)!=0: raise OSError(ctypes.get_errno(),'exclusive rename')

def remove_exact(p,expected,checkpoint=lambda _:None):
    current=fingerprint(p)
    if 'tree' in expected and 'tree' in current:
        # A previous rollback may have stopped after deleting some children. Never accept additions/changes.
        okay=all(current[k]==expected[k] for k in ['inode','device','mode']) and all(k in expected['tree'] and expected['tree'][k]==v for k,v in current['tree'].items())
    else:okay=current==expected
    if not okay: raise Stop('Changed/foreign destination retained: '+str(p))
    if p.is_dir():
        for child in sorted(p.rglob('*'),key=lambda x:len(x.parts),reverse=True):
            if child.is_dir():child.rmdir()
            else:child.unlink()
            checkpoint('removed-child:'+child.relative_to(p).as_posix())
        p.rmdir()
    else:p.unlink()
    syncdir(p.parent)

class Transaction:
    """All paths fixed by constructor, never from journal or XPC. Mock launchd only in tests."""
    mode = 'acceptance-only'
    def destinations(self):
        return {'base':self.base, 'plist':self.plist}
    def prepare_services(self,payload,helper):
        return {'plist':{'Label':LABEL,'ProgramArguments':[helper,'--serve-acceptance'],'MachServices':{LABEL:True},'RunAtLoad':True,'KeepAlive':False}}
    def __init__(self,base,plist,journal,service,uid=0,fault=lambda _:None):
        self.base,self.plist,self.journal,self.service,self.uid,self.fault=base,plist,journal,service,uid,fault
        self.state=None
    def save(self,event):
        self.state['events'].append(event)
        temp=self.journal.with_name(self.journal.name+'.next-'+str(uuid.uuid4()))
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as f:json.dump(self.state,f,sort_keys=True);f.flush();os.fsync(f.fileno())
        os.replace(temp,self.journal);syncdir(self.journal.parent)
        self.fault(event)
    def load(self):
        secure(self.journal,self.uid,False)
        self.state=json.loads(self.journal.read_text())
        if self.state.get('version')!=1 or self.state.get('mode')!=self.mode: raise Stop('Unknown transaction')
        uuid.UUID(self.state['id'])
        if set(self.state['moves'])-set(self.destinations()):raise Stop('Invalid journal moves')
    @property
    def stage(self): return self.base.parent/('.NeSpatAcceptance-'+self.state['id'])
    def install(self,files,manifest,probe):
        if not probe():raise Stop('Unknown preflight')
        if os.path.lexists(self.journal):
            self.load()
            if self.state['phase']!='rolled-back' or self.base.exists() or self.plist.exists() or self.service.loaded():
                raise Stop('Use explicit resume/rollback, never overwrite journal')
            archived=self.journal.with_name(self.journal.name+'.completed-'+self.state['id'])
            rename_exclusive(self.journal,archived);syncdir(self.journal.parent)

        if any(os.path.lexists(p) for p in self.destinations().values()):raise Stop('Conflict')
        self.state={'version':1,'mode':self.mode,'id':str(uuid.uuid4()),'phase':'preparing','moves':{},'events':[],
            'plan':{'base':str(self.base),'plist':str(self.plist),'service':LABEL,
                'files':{('LocalTrust/profile.json' if n=='profile.json' else n):{'sha256':SHA(b),'mode':manifest['files'][n]['mode']} for n,b in files.items()}}}
        self.state['plan']['stage']=str(self.stage)
        try:
            self.save('reserved')
            self.stage.mkdir(mode=0o700);syncdir(self.stage.parent);self.save('stage-created')
            payload=self.stage/'base';payload.mkdir(mode=0o755)
            for name,b in files.items():
                dest=payload/('LocalTrust/profile.json' if name=='profile.json' else name)
                dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(b);dest.chmod(manifest['files'][name]['mode'])
                with dest.open('rb') as f:os.fsync(f.fileno())
                self.fault('staged-file:'+name)
            for d in sorted([p for p in payload.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):d.chmod(0o755);syncdir(d)
            syncdir(payload)
            helper=str(self.base/'NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper')
            sources={'base':payload}
            for name,spec in self.prepare_services(payload,helper).items():
                plist=self.stage/(name+'.plist')
                plist.write_bytes(plistlib.dumps(spec));plist.chmod(0o644)
                with plist.open('rb') as f:os.fsync(f.fileno())
                sources[name]=plist
            syncdir(self.stage)
            self.service.verify(payload)
            self.state['moves']={name:fingerprint(src) for name,src in sources.items()};self.save('prepared')
            for name,src in sources.items():
                dst=self.destinations()[name]
                self.save('before-'+name);rename_exclusive(src,dst);self.fault('renamed-'+name);syncdir(dst.parent);self.save('after-'+name)
            self.save('before-bootstrap');self.service.bootstrap(self.plist);self.save('after-bootstrap')
            self.state['phase']='installed';self.save('committed')
        except Exception:
            if self.journal.exists():self.rollback()
            raise
    def rollback(self):
        if self.state is None:self.load()
        if self.state['phase']=='rolled-back':return
        # A bootstrap may have succeeded before the process died. Resolve actual service, don't trust last event.
        if self.service.loaded():
            if not self.base.exists() or not self.plist.exists():raise Stop('Service ownership unknown')
            for name,p in [('base',self.base),('plist',self.plist)]:
                if name not in self.state['moves'] or fingerprint(p)!=self.state['moves'][name]:raise Stop('Foreign service retained')
            self.service.bootout()
            if self.service.loaded():raise Stop('Bootout unconfirmed')
        self.save('service-stopped')
        for name,p in [('plist',self.plist),('base',self.base)]:
            if os.path.lexists(p):
                if name not in self.state['moves']:raise Stop('No ownership proof')
                remove_exact(p,self.state['moves'][name],self.fault)
            self.save('removed-'+name)
        # Private stage belongs to this durable transaction; no client can access it. Unknown links STOP.
        if self.stage.exists():
            secure(self.stage,self.uid)
            remove_exact(self.stage,fingerprint(self.stage))
        self.state['phase']='rolled-back';self.save('rolled-back')

class Launchd:
    def __init__(self,profile):self.profile=profile
    def verify(self,payload):signatures(payload/'NeSpat.app',self.profile)
    def loaded(self):
        r=subprocess.run(['/bin/launchctl','print','system/'+LABEL],capture_output=True,text=True)
        if r.returncode==0:return True
        if r.returncode==113 and 'Could not find service' in r.stderr:return False
        raise Stop('Unknown launchd state')
    def bootstrap(self,p):checked_run(['/bin/launchctl','bootstrap','system',str(p)])
    def bootout(self):checked_run(['/bin/launchctl','bootout','system/'+LABEL])

def main():
    if len(sys.argv)!=5 or sys.argv[1] not in ['preflight','install','rollback','resume']:raise Stop('MODE PACKAGE_ZIP SHA256 ARTIFACT_DIRECTORY required')
    if os.geteuid()!=0:raise Stop('Root context requires separate explicit user approval')
    mode,archive,digest,artifact=sys.argv[1:];data=Path(archive).read_bytes();files,manifest,profile=package(data,digest)
    service=Launchd(profile);tx=Transaction(BASE,PLIST,JOURNAL,service)
    # Fixed parent lock excludes install/resume/rollback races without creating a lock file in read-only preflight.
    secure(BASE.parent);fd=os.open(BASE.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if mode=='preflight':
            system_probe(Path(artifact),profile)
            print(json.dumps({'preflight':'OK','writes':False,'base':str(BASE),'daemonPlist':str(PLIST),'transactionJournal':str(JOURNAL),
                'stageTemplate':str(BASE.parent/'.NeSpatAcceptance-<transaction UUID>'),'files':manifest['files'],
                'GUIAgentInstalled':False,'fullGrants':False,'powerExecutor':False},sort_keys=True))
            return
        if mode in ['rollback','resume']:tx.load();tx.rollback();print('transaction rolled back; installation not resumed implicitly');return
        tx.install(files,manifest,lambda:system_probe(Path(artifact),profile));print('acceptance-only installed; no power executor, no GUI startup')
    finally:os.close(fd)
if __name__=='__main__':
    try:main()
    except Exception as e:print('STOP:',e,file=sys.stderr);sys.exit(2)
