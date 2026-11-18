#!/usr/bin/python3 -B
"""Read-only complete MacBook baseline. Missing Battery output is STOP, never a default.

Run both captures as the same ordinary user outside the restricted tool sandbox.
This utility has no setter, installation, service or privilege escalation path.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys

REQUIRED = {'Battery Power', 'AC Power'}

def parse_custom(text):
    profiles = {}; current = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace() and line.endswith(':'):
            current = line[:-1]
            if current not in REQUIRED or current in profiles:
                raise ValueError('Unknown or duplicate profile')
            profiles[current] = {}
        else:
            if current is None or not line[0].isspace():
                raise ValueError('Malformed profile')
            parts = line.strip().rsplit(None, 1)
            if len(parts) != 2 or parts[0] in profiles[current]:
                raise ValueError('Malformed or duplicate setting')
            profiles[current][parts[0]] = parts[1]
    if set(profiles) != REQUIRED or any(not v for v in profiles.values()):
        raise ValueError('Incomplete MacBook power profiles: STOP')
    return profiles

def checked(argv):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=15)
    if p.returncode or p.stderr.strip():
        raise ValueError('Read failed: '+repr(argv)+': '+p.stderr)
    return p.stdout

def capture():
    if platform.system() != 'Darwin' or os.getuid() == 0 or os.getuid() != os.geteuid():
        raise ValueError('Same ordinary macOS user required')
    raw = checked(['/usr/bin/pmset', '-g', 'custom'])
    profiles = parse_custom(raw)
    # Independently require real battery visibility and exact IOKit SleepDisabled = No.
    battery = plistlib.loads(checked(['/usr/sbin/ioreg', '-a', '-r', '-c', 'AppleSmartBattery']).encode())
    domain = plistlib.loads(checked(['/usr/sbin/ioreg', '-a', '-r', '-c', 'IOPMrootDomain']).encode())
    values = [e['SleepDisabled'] for e in domain if 'SleepDisabled' in e]
    if len(battery) != 1 or len(values) != 1 or type(values[0]) is not bool or values[0] is not False:
        raise ValueError('Battery / SleepDisabled not confirmed: STOP')
    return {'version': 1, 'timestamp_UTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'context': {'uid': os.getuid(), 'boot': checked(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']).strip(),
                        'os': checked(['/usr/bin/sw_vers', '-buildVersion']).strip(), 'architecture': platform.machine(),
                        'pmset_sha256': hashlib.sha256(Path('/usr/bin/pmset').read_bytes()).hexdigest()},
            'profiles': profiles, 'raw_custom': raw, 'SleepDisabled': False}

def compare(before, after):
    for s in (before, after):
        if s.get('version') != 1 or s.get('SleepDisabled') is not False or s.get('profiles') != parse_custom(s['raw_custom']):
            raise ValueError('Invalid baseline')
        if set(s['context']) != {'uid', 'boot', 'os', 'architecture', 'pmset_sha256'}:
            raise ValueError('Incomplete context')
    if before['context'] != after['context'] or before['profiles'] != after['profiles']:
        raise ValueError('Context or settings changed: STOP')

if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--capture']:
            print(json.dumps(capture(), indent=2, sort_keys=True))
        elif len(sys.argv) == 4 and sys.argv[1] == '--compare':
            compare(json.loads(Path(sys.argv[2]).read_text()), json.loads(Path(sys.argv[3]).read_text()))
            print('COMPLETE SAME-CONTEXT BASELINES MATCH; no live transition implied')
        else:
            raise ValueError('Usage: --capture | --compare BEFORE AFTER')
    except Exception as error:
        print('STOP: '+str(error), file=sys.stderr)
        raise SystemExit(2)
