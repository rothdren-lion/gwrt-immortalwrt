#!/usr/bin/env python3
"""Run the real luci-app-nfs init against a private root and mocked helpers."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'gwrt-overlays/feeds/luci/applications/luci-app-nfs/root/etc/init.d/nfs'

RC_COMMON = '''#!/bin/sh
config_load() { CFGDIR="$FIXTURE/fixture"; }
config_get() {
	local __v="$1" __s="$2" __o="$3" __d="$4" __c=0
	case "$__o" in
		enabled) __c=2 ;; path) __c=3 ;; clients) __c=4 ;;
		options) __c=5 ;; gwrt_auto) __c=6 ;; target) __c=7 ;;
		source) __c=8 ;; delay) __c=9 ;;
	esac
	local __val=""
	[ -f "$CFG" ] && __val=$(awk -F"|" -v s="$__s" -v c="$__c" '$1==s {print $c}' "$CFG" 2>/dev/null | head -n1)
	[ -n "$__val" ] || __val="$__d"
	eval "$__v=\\"\\$__val\\""
}
config_get_bool() {
	local __v="$1"; shift
	config_get "__tmp" "$@"
	[ "$__tmp" = 1 ] && __tmp=1 || __tmp=0
	eval "$__v=\\"\\$__tmp\\""
}
config_foreach() {
	local __fn="$1" __cfg="$2" __s __old="$CFG"
	CFG="$CFGDIR/$__cfg.list"
	[ -f "$CFG" ] || { CFG="$__old"; return 0; }
	for __s in $(awk -F"|" '{print $1}' "$CFG"); do "$__fn" "$__s"; done
	CFG="$__old"
}
'''


class NfsInit(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='gwrt-nfs-test-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        for d in ('etc/exports.d', 'etc/init.d', 'var/run', 'run', 'proc', 'mnt/data', 'bin', 'fixture'):
            (self.root / d).mkdir(parents=True)
        (self.root / 'proc/mounts').write_text('/dev/root / squashfs ro 0 0\n')
        (self.root / 'etc/rc.common').write_text(RC_COMMON)

        def mock(name, body):
            p = self.root / 'bin' / name
            p.write_text('#!/bin/sh\n' + textwrap.dedent(body).format(root=self.root))
            p.chmod(0o755)

        mock('exportfs', '''
            echo "exportfs $*" >> {root}/calls
            [ "$1" = "-s" ] && cat {root}/exports-state 2>/dev/null
            exit 0
        ''')
        mock('uci', '''
            [ "$1" = "-q" ] && shift
            [ "$1" = "get" ] && shift
            [ -f "$FIXTURE/fixture/uci.$1" ] && cat "$FIXTURE/fixture/uci.$1" && exit 0
            exit 1
        ''')
        mock('mount', '''
            echo "mount $*" >> {root}/calls
            echo "$4 $5 nfs4 rw 0 0" >> {root}/proc/mounts
        ''')
        (self.root / 'etc/init.d/nfsd').write_text(textwrap.dedent('''\
            #!/bin/sh
            echo "nfsd $1" >> {root}/calls
            case "$1" in
                status) [ -f {root}/run/nfsd ] && exit 0 || exit 1 ;;
                start) touch {root}/run/nfsd ;;
                stop) rm -f {root}/run/nfsd ;;
            esac
        ''').format(root=self.root))
        (self.root / 'etc/init.d/nfsd').chmod(0o755)

        text = SCRIPT.read_text()
        text = text.replace('#!/bin/sh /etc/rc.common',
                            f'#!/bin/sh\n. {self.root}/etc/rc.common')
        text = text.replace('/etc/exports.d', f'{self.root}/etc/exports.d')
        text = text.replace('/var/run', f'{self.root}/var/run')
        text = text.replace('/proc/mounts', f'{self.root}/proc/mounts')
        text = text.replace('/etc/init.d/', f'{self.root}/etc/init.d/')
        text = text.replace('/usr/sbin/nfsv4.exportd', f'{self.root}/usr/sbin/nfsv4.exportd')
        self.script = self.root / 'init-nfs'
        self.script.write_text(text + '\n"$@"\n')

    def run_init(self, action='start'):
        env = dict(os.environ, PATH=f'{self.root}/bin:/usr/bin:/bin', FIXTURE=str(self.root))
        return subprocess.run(['sh', str(self.script), action], env=env,
                              capture_output=True, text=True, timeout=60)

    def shares(self, *rows):
        (self.root / 'fixture/share.list').write_text('\n'.join(
            '|'.join(str(c) for c in row) for row in rows) + '\n')

    def exports(self):
        p = self.root / 'etc/exports.d/gwrt-luci.exports'
        return p.read_text() if p.exists() else ''

    def calls(self):
        p = self.root / 'calls'
        return p.read_text() if p.exists() else ''

    def test_disabled_share_writes_no_export_and_leaves_server_stopped(self):
        self.shares(('share', 0, str(self.root / 'mnt/data'), '*', 'rw,sync', 0))
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.exports(), '')
        self.assertNotIn('nfsd start', self.calls())

    def test_enabled_share_exports_and_starts_owned_server(self):
        self.shares(('share', 1, str(self.root / 'mnt/data'), '192.168.3.0/24', 'rw,sync,no_subtree_check', 0))
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.exports(), f'{self.root}/mnt/data '
                         '192.168.3.0/24(rw,sync,no_subtree_check)\n')
        self.assertIn('nfsd start', self.calls())
        self.assertIn('exportfs -r', self.calls())

    def test_managed_share_requires_the_recorded_mount(self):
        data = self.root / 'mnt/data'
        self.shares(('share', 1, str(data), '*', 'rw', 1))
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.exports(), '')

        (self.root / 'fixture/uci.gwrt.storage.mount').write_text('/mnt/other\n')
        (self.root / 'fixture/uci.gwrt.storage.device').write_text('/dev/mmcblk0p27\n')
        self.run_init()
        self.assertEqual(self.exports(), '')

    def test_mounted_managed_share_is_exported(self):
        data = self.root / 'mnt/data'
        (self.root / 'proc/mounts').write_text(
            f'/dev/mmcblk0p27 {data} ext4 rw 0 0\n')
        self.shares(('share', 1, str(data), '*', 'rw', 1))
        (self.root / 'fixture/uci.gwrt.storage.mount').write_text(f'{data}\n')
        (self.root / 'fixture/uci.gwrt.storage.device').write_text('/dev/mmcblk0p27\n')
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'{data} *(rw)', self.exports())

    def test_unmounted_managed_share_stays_private(self):
        data = self.root / 'mnt/data'
        self.shares(('share', 1, str(data), '*', 'rw', 1))
        (self.root / 'fixture/uci.gwrt.storage.mount').write_text(f'{data}\n')
        (self.root / 'fixture/uci.gwrt.storage.device').write_text('/dev/mmcblk0p27\n')
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.exports(), '')
        self.assertNotIn('nfsd start', self.calls())

    def test_rejects_relative_and_traversal_paths(self):
        for path in ('mnt/data', f'{self.root}/mnt/../../etc', '/mnt/da ta'):
            self.shares(('share', 1, path, '*', 'rw', 0))
            self.run_init()
            self.assertEqual(self.exports(), '', path)

    def test_stop_withdraws_exports_and_stops_only_owned_server(self):
        self.shares(('share', 1, str(self.root / 'mnt/data'), '*', 'rw', 0))
        self.run_init()
        (self.root / 'exports-state').write_text('')
        result = self.run_init('stop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.exports(), '')
        self.assertIn('nfsd stop', self.calls())

    def test_foreign_exports_keep_a_running_server(self):
        (self.root / 'etc/exports').write_text('/srv/keep *(ro)\n')
        (self.root / 'exports-state').write_text('/srv/keep\n')
        (self.root / 'var/run/nfsd').touch()
        self.shares(('share', 0, str(self.root / 'mnt/data'), '*', 'rw', 0))
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('nfsd stop', self.calls())


if __name__ == '__main__':
    unittest.main(verbosity=2)