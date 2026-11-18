#!/usr/bin/python3 -IB
"""Admin-only local installation. Activation is a separate, explicit operation."""
import base64
import fcntl
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import uuid

common = runpy.run_path(str(Path(__file__).with_name('acceptance-install.py')))
Stop = common['Stop']
BASE, PLIST, LABEL = (common[k] for k in ('BASE','PLIST','LABEL'))
WATCH = 'local.nespat.recovery'
WATCH_PLIST = PLIST.with_name(WATCH+'.plist')
JOURNAL = BASE.parent/'.NeSpatExclusiveTransaction.json'
PROFILE = BASE/'LocalTrust/profile.json'
HELPER = BASE/'NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper'
secure, fingerprint, syncdir = (common[k] for k in ('secure','fingerprint','syncdir'))

def loaded(label):
    result=subprocess.run(['/bin/launchctl','print','system/'+label],capture_output=True,text=True)
    if result.returncode==0:return True
    if result.returncode==113 and 'Could not find service' in result.stderr:return False
    raise Stop('Unknown launchd status for '+label)

def run(*argv):
    subprocess.run(list(map(str,argv)),check=True,timeout=30)

class Services(common['Launchd']):
    def loaded(self):return loaded(WATCH) or loaded(LABEL)
    def bootstrap(self,p):
        run('/bin/launchctl','bootstrap','system',WATCH_PLIST)
        run('/bin/launchctl','bootstrap','system',p)

class Transaction(common['Transaction']):
    mode='exclusive'
    def destinations(self):
        return dict(base=self.base,plist=self.plist,watch=WATCH_PLIST)
    def prepare_services(self,payload,helper):
        state=payload/'State'
        state.mkdir(mode=0o700)
        (payload/'Runtime').mkdir(mode=0o755)
        empty=b'{"generation":1,"version":2}'
        initial=json.dumps({'payload':base64.b64encode(empty).decode(),'sha256':common['SHA'](empty)},separators=(',',':'),sort_keys=True).encode()
        for name,data in [('authority.json',initial),('lock',b''),('setter.lock',b'')]:
            file=state/name
            with file.open('xb') as f:
                os.fchmod(f.fileno(),0o600);f.write(data);f.flush();os.fsync(f.fileno())
        syncdir(state);syncdir(payload)
        def daemon(label,arg):
            return dict(Label=label,ProgramArguments=[helper,arg],RunAtLoad=True,KeepAlive=True,ThrottleInterval=2)
        server=daemon(LABEL,'--serve-local');server['MachServices']={LABEL:True}
        return dict(plist=server,watch=daemon(WATCH,'--watch-exclusive'))

    def validate_payload(self):
        expected=self.state['moves']['base']
        current=fingerprint(self.base)
        if any(current[k]!=expected[k] for k in ('inode','device','mode')):raise Stop('Different installed base')
        editable={'LocalTrust/profile.json','State/authority.json','Runtime/helper.json','Runtime/watchdog.json','State/trial-spent'}
        for name,entry in current['tree'].items():
            if name in editable:
                secure(self.base/name,0,False)
            elif expected['tree'].get(name)!=entry:raise Stop('Unknown or changed file: '+name)
        if set(expected['tree'])-set(current['tree']):raise Stop('Missing installed file')
        profile=json.loads(PROFILE.read_bytes())
        template=self.service.profile
        if any(profile.get(k)!=v for k,v in template.items() if k!='enabled') or set(profile)-set(template)-{'trialBoot','trialExpires'}:
            raise Stop('Installed authority changed')
        self.service.verify(self.base)
        return profile

    def rollback(self):
        if self.state is None:self.load()
        if self.state['phase']=='rolled-back':return
        dest=self.destinations()
        for name,label in [('plist',LABEL),('watch',WATCH)]:
            if os.path.lexists(dest[name]):
                if self.state['moves'].get(name)!=fingerprint(dest[name]):raise Stop('Foreign service retained')
            elif loaded(label):raise Stop('Unproven service retained')
        if self.base.exists() and 'removed-base' not in self.state['events']:
            if self.state['phase']!='removing':
                profile=self.validate_payload()
                profile['enabled']=False
                save_profile(profile)
                # Helper and watchdog remain running if recovery is still outstanding.
                run(HELPER,'--check-removable')
                if loaded(LABEL):run('/bin/launchctl','bootout','system/'+LABEL)
                run(HELPER,'--check-removable')
                if loaded(WATCH):run('/bin/launchctl','bootout','system/'+WATCH)
                if loaded(LABEL) or loaded(WATCH):raise Stop('Service removal unconfirmed')
                run(HELPER,'--check-removable')
                self.validate_payload()
                self.state['moves']['base']=fingerprint(self.base)
                self.state['phase']='removing';self.save('safe-to-remove')
        if self.service.loaded():raise Stop('Service still loaded')
        for name in ('watch','plist','base'):
            if os.path.lexists(dest[name]):
                if name not in self.state['moves']:raise Stop('Unknown destination')
                common['remove_exact'](dest[name],self.state['moves'][name])
            self.save('removed-'+name)
        if self.stage.exists():
            secure(self.stage)
            common['remove_exact'](self.stage,fingerprint(self.stage))
        self.state['phase']='rolled-back';self.save('rolled-back')

def save_profile(profile):
    candidate=PROFILE.with_name('profile-'+str(uuid.uuid4())+'.next')
    with candidate.open('x') as f:
        os.fchmod(f.fileno(),0o644);json.dump(profile,f);f.flush();os.fsync(f.fileno())
    os.replace(candidate,PROFILE);syncdir(PROFILE.parent)

def main():
    if os.geteuid()!=0 or len(sys.argv)!=5:raise Stop('Administrator required: MODE ZIP REVIEWED_SHA256 ARTIFACT_DIRECTORY')
    mode,archive,digest,artifact=sys.argv[1:]
    files,manifest,profile=common['package'](Path(archive).read_bytes(),digest,mode='exclusive')
    service=Services(profile)
    tx=Transaction(BASE,PLIST,JOURNAL,service)
    secure(BASE.parent)
    fd=os.open(BASE.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if mode=='install-disabled':
            def preflight():
                if os.path.lexists(WATCH_PLIST) or loaded(WATCH):raise Stop('Watchdog conflict')
                return common['system_probe'](Path(artifact),profile)
            tx.install(files,manifest,preflight)
        elif mode=='rollback':tx.rollback()
        elif mode in ('approve-single-trial','approve-production'):
            tx.load()
            if tx.state['phase']!='installed' or not loaded(WATCH) or not loaded(LABEL):raise Stop('Incomplete installation')
            current=tx.validate_payload()
            if current['enabled'] or profile['trialOnly']!=(mode=='approve-single-trial'):raise Stop('Authority mismatch')
            run(HELPER,'--check-removable')
            run(HELPER,'--check-local')
            if profile['trialOnly']:
                if (BASE/'State/trial-spent').exists():raise Stop('Trial already consumed')
                import ctypes
                kernel=ctypes.CDLL(None)
                kernel.clock_gettime_nsec_np.argtypes=[ctypes.c_int];kernel.clock_gettime_nsec_np.restype=ctypes.c_uint64
                # CLOCK_MONOTONIC_RAW in Darwin time.h matches RecoveryPolicy.continuousSeconds.
                current['trialExpires']=kernel.clock_gettime_nsec_np(4)/1e9+120
                current['trialBoot']=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.bootsessionuuid'],text=True).strip()
            current['enabled']=True
            save_profile(current)
        else:raise Stop('Unknown operation')
    finally:os.close(fd)
if __name__=='__main__':
    try:main()
    except Exception as e:print('STOP:',e,file=sys.stderr);sys.exit(2)
