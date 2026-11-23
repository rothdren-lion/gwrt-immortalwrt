#!/usr/bin/env python3
"""Run the real eMMC shell helper against private sysfs/dev/UCI fixtures."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'package/gwrt-emmc-storage/files/gwrt-emmc-storage'
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
r=Path(os.environ['FIXTURE']); name=Path(sys.argv[0]).name; a=sys.argv[1:]
f=r/'uci.json'; state=json.loads(f.read_text()); disk=json.loads((r/'disks.json').read_text())
with (r/'calls').open('a') as out: out.write(name+' '+ ' '.join(a)+'\n')
if name=='uci':
 a=[x for x in a if x!='-q']; op=a.pop(0); key=a[0] if a else ''
 if op=='get':
  if key not in state: sys.exit(1)
  print(state[key])
 elif op=='set':
  k,v=key.split('=',1); state[k]=v; f.write_text(json.dumps(state))
 elif op=='delete':
  for k in list(state):
   if k==key or k.startswith(key+'.'): del state[k]
  f.write_text(json.dumps(state))
 elif op=='show':
  for k,v in state.items():
   if k==key or k.startswith(key+'.'): print(k+"='"+v+"'" if '.' in k.split('.',1)[-1] else k+'='+v)
 elif op=='changes': print('changed')
 sys.exit(0)
if name=='blkid':
 item=disk.get(Path(a[-1]).name,{})
 if item.get('probe_error'): sys.exit(4)
 for k,v in item.items():
  if k!='probe_error': print(k+'='+str(v))
 sys.exit(0 if item.get('TYPE') else 2)
if name=='mkswap':
 key=Path(a[-1]).name; disk[key]['TYPE']='swap'; (r/'disks.json').write_text(json.dumps(disk)); sys.exit(0)
if name=='swapon':
 with (r/'proc/swaps').open('a') as out: out.write(a[-1]+' partition 1024 0 -2\n')
 sys.exit(0)
if name=='mount':
 if os.environ.get('MOUNT_FAIL'): sys.exit(1)
 with (r/'proc/mounts').open('a') as out: out.write(a[-2]+' '+a[-1]+' ext4 rw,noatime 0 0\n')
 sys.exit(0)
if name=='id': print('1000'); sys.exit(0)
if name=='pdbedit': sys.exit(1)
if name=='smbpasswd':
 sys.stdin.read() if '-a' in a else None
 sys.exit(0)
sys.exit(0)
'''


class Storage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='gwrt-emmc-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for d in ['sys/class/block', 'dev', 'proc/self', 'etc/config', 'var/run', 'mnt', 'bin']:
            (self.root / d).mkdir(parents=True, exist_ok=True)
        for f in ['proc/mounts', 'proc/self/mountinfo', 'calls', 'etc/passwd']:
            (self.root / f).write_text('')
        (self.root / 'proc/swaps').write_text('Filename Type Size Used Priority\n')
        self.state = {}
        self.disks = {}
        (self.root / 'uci.json').write_text('{}')
        (self.root / 'disks.json').write_text('{}')
        for cmd in ['uci','blkid','mkswap','swapon','mount','logger','chown','adduser','useradd','pdbedit','smbpasswd','id']:
            p = self.root / 'bin' / cmd
            p.write_text(MOCK)
            p.chmod(0o755)
        self.env = dict(os.environ, FIXTURE=str(self.root), PATH=str(self.root / 'bin')+':'+os.environ['PATH'])

    def disk(self, name='mmcblk0', kind='MMC', removable='0'):
        p = self.root / 'sys/class/block' / name
        (p / 'device').mkdir(parents=True)
        (p / 'device/type').write_text(kind+'\n')
        (p / 'removable').write_text(removable+'\n')

    def part(self, number, *, name='data', fs='ext4', guid='', size=4_194_304, start=None):
        block = f'mmcblk0p{number}'
        p = self.root / 'sys/class/block' / block
        (p / 'holders').mkdir(parents=True)
        for f,v in {'partition':number, 'size':size, 'start':start if start is not None else number*8_388_608, 'dev':f'179:{number}'}.items():
            (p / f).write_text(str(v)+'\n')
        (self.root / 'dev' / block).write_bytes(b'not a real block device')
        self.disks[block] = {'PART_ENTRY_NAME':name, 'PART_ENTRY_TYPE':guid}
        if fs: self.disks[block]['TYPE'] = fs
        return self.root / 'dev' / block

    def run_helper(self, extra_env=None):
        self.assertTrue(HELPER.exists(), 'eMMC startup helper is not installed yet')
        text = HELPER.read_text()
        for old in ['/sys/class/block','/proc/self/mountinfo','/proc/mounts','/proc/swaps','/var/run','/etc/config','/etc/passwd','/mnt']:
            text = text.replace(old, str(self.root)+old)
        text = re.sub(r'/dev(?=/)', str(self.root)+'/dev', text)
        text = text.replace(str(self.root)+'/mnt/sda1/aria2', '/mnt/sda1/aria2')
        text = text.replace('[ -b ', '[ -f ')
        script = self.root / 'run.sh'
        script.write_text(text)
        (self.root / 'uci.json').write_text(json.dumps(self.state))
        (self.root / 'disks.json').write_text(json.dumps(self.disks))
        proc = subprocess.run(['/usr/bin/busybox','sh',str(script),'prepare'], env=dict(self.env,**(extra_env or {})), capture_output=True,text=True,timeout=12)
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        self.state = json.loads((self.root / 'uci.json').read_text())
        self.disks = json.loads((self.root / 'disks.json').read_text())
        return (self.root / 'calls').read_text()

    def test_unformatted_dedicated_swap_initializes_once(self):
        self.disk(); self.part(26,name='swap',fs='',size=1_048_576); self.part(27)
        calls=self.run_helper()
        self.assertEqual(calls.count('mkswap '),1)
        self.assertIn('swapon ',calls)
        self.assertIn('fstab.gwrt_emmc_swap_mmcblk0p26.enabled',self.state)
        self.run_helper()
        self.assertEqual((self.root/'calls').read_text().count('mkswap '),1)

    def test_existing_swap_is_never_reformatted(self):
        self.disk(); self.part(26,name='swap',fs='swap',size=1_048_576); self.part(27)
        calls=self.run_helper()
        self.assertNotIn('mkswap ',calls); self.assertIn('swapon ',calls)

    def test_filesystem_on_swap_label_is_preserved(self):
        self.disk(); self.part(26,name='swap',fs='ext4'); self.part(27)
        calls=self.run_helper()
        self.assertNotIn('mkswap ',calls); self.assertNotIn('swapon ',calls)

    def test_unknown_blank_and_failed_probe_are_never_formatted(self):
        self.disk(); self.part(25,name='rootfs_data',fs='',size=8_388_608)
        self.part(26,name='swap',fs='',size=1_048_576)
        self.disks['mmcblk0p26']['probe_error']=True
        self.part(27,name='data',fs='')
        calls=self.run_helper()
        self.assertNotIn('mkswap ',calls); self.assertNotIn('mount ',calls)
        self.assertFalse(any((self.root/'mnt').iterdir()))

    def test_last_data_partition_excludes_system_and_sd(self):
        self.disk(); self.part(25,size=16_777_216); self.part(27,size=4_194_304)
        self.part(28,name='rootfs_data',size=32_000_000)
        calls=self.run_helper()
        self.assertTrue(self.state['gwrt.storage.device'].endswith('mmcblk0p27'))
        self.assertIn('mount ',calls)

    def test_sd_and_non_emmc_leave_config_untouched(self):
        self.disk(kind='SD'); self.part(27)
        calls=self.run_helper()
        self.assertEqual(self.state,{})
        self.assertNotIn('mount ',calls); self.assertNotIn('mkswap ',calls)

    def test_mounted_swap_and_holders_are_ignored(self):
        self.disk(); d=self.part(26,name='swap',fs='',size=1_048_576)
        (self.root/'sys/class/block/mmcblk0p26/holders/dm-0').touch()
        self.part(27)
        calls=self.run_helper()
        self.assertNotIn('mkswap ',calls); self.assertNotIn('swapon ',calls)

    def test_failed_mount_never_creates_downloads_or_shares(self):
        self.disk(); self.part(27)
        for p in ['aria2','samba4','nfs']: (self.root/'etc/config'/p).touch()
        calls=self.run_helper({'MOUNT_FAIL':'1'})
        self.assertNotIn('gwrt.storage.mount',self.state)
        self.assertNotIn('samba4.smb_share.path',self.state)
        self.assertFalse(list((self.root/'mnt').glob('*/downloads')))

    def test_paths_permissions_and_nfs_fields_are_ready_but_not_started(self):
        self.disk(); self.part(27)
        for p in ['aria2','samba4','nfs']: (self.root/'etc/config'/p).touch()
        self.state={'aria2.main':'aria2','aria2.main.enabled':'0','aria2.main.user':'aria2','aria2.main.dir':'/mnt/sda1/aria2', 'network.lan.ipaddr':'192.168.3.3','network.lan.netmask':'255.255.255.0'}
        calls=self.run_helper()
        mount=self.state['gwrt.storage.mount']
        self.assertEqual(self.state['samba4.smb_share.path'],mount)
        self.assertEqual(self.state['nfs.gwrt_share.path'],mount)
        self.assertEqual(self.state['nfs.gwrt_share.enabled'],'0')
        self.assertEqual(self.state['nfs.gwrt_share.clients'],'192.168.3.0/24')
        self.assertIn('rw',self.state['nfs.gwrt_share.options'])
        self.assertEqual(self.state['aria2.main.enabled'],'0')
        self.assertEqual(self.state['aria2.main.dir'],mount+'/downloads/aria2')
        self.assertIn('chown aria2 ',calls)
        self.assertNotIn(' restart',calls); self.assertNotIn(' start\n',calls)

    def test_custom_shares_downloads_and_credentials_are_preserved(self):
        self.disk(); self.part(27)
        for p in ['aria2','samba4','nfs']: (self.root/'etc/config'/p).touch()
        self.state={'aria2.main':'aria2','aria2.main.dir':'/custom/downloads','aria2.main.enabled':'1','aria2.main.rpc_secret':'saved-secret','samba4.user':'sambashare','samba4.user.path':'/custom/share','nfs.user':'share','nfs.user.path':'/custom/nfs','nfs.user.enabled':'1'}
        self.run_helper()
        for key,val in {'aria2.main.dir':'/custom/downloads','aria2.main.enabled':'1','aria2.main.rpc_secret':'saved-secret','samba4.user.path':'/custom/share','nfs.user.path':'/custom/nfs','nfs.user.enabled':'1'}.items():
            self.assertEqual(self.state[key],val)


if __name__ == '__main__': unittest.main(verbosity=2)
