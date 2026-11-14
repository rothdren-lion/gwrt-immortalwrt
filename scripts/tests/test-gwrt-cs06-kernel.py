#!/usr/bin/env python3
"""Check CS-06 kernel selection with target and toolchain trees together."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'gwrt-verify-cs06-kernel.py'
CONFIG = ('CONFIG_ARM64=y\nCONFIG_CMA=y\nCONFIG_DMA_CMA=y\n'
          'CONFIG_CMA_SIZE_SEL_MBYTES=y\nCONFIG_CMA_SIZE_MBYTES=64\n')
TARGET = 'target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq53xx'


class KernelSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gwrt-cs06-kernel-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / 'build_dir'
        self.output = self.root / 'logs/cs06-kernel.config'
        # Deliberately create the same-version toolchain tree first.
        self.add_kernel('toolchain-aarch64_gcc_musl', cma=32)

    def add_kernel(self, parent=TARGET, version='6.18.62', cma=64):
        kernel = self.build / parent / ('linux-' + version)
        kernel.mkdir(parents=True)
        (kernel / '.config').write_text(CONFIG.replace(
            'CONFIG_CMA_SIZE_MBYTES=64', f'CONFIG_CMA_SIZE_MBYTES={cma}'))
        release = kernel / 'include/config/kernel.release'
        release.parent.mkdir(parents=True)
        release.write_text(version + '\n')
        return kernel

    def check(self, succeeds, message):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.build),
                                 '--output', str(self.output)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if succeeds else 1,
                         result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)
        self.assertEqual(self.output.exists(), succeeds)
        return result

    def test_selects_target_despite_toolchain_and_other_board(self):
        self.add_kernel('target-aarch64_musl/linux-qualcommax_ipq60xx', cma=16)
        kernel = self.add_kernel()
        result = self.check(True, str(kernel))
        self.assertEqual(self.output.read_bytes(), (kernel / '.config').read_bytes())
        self.assertNotIn('toolchain', result.stdout)

    def test_toolchain_alone_is_not_a_target(self):
        self.check(False, 'expected exactly one CS-06 target kernel; found: none')

    def test_wrong_target_cma_fails_even_with_valid_toolchain(self):
        self.add_kernel('toolchain-other_musl', cma=64)
        self.add_kernel(cma=32)
        self.check(False, 'actual: CONFIG_CMA_SIZE_MBYTES=32')

    def test_wrong_kernel_version(self):
        self.add_kernel(version='6.18.55')
        self.check(False, 'expected Linux 6.18.62, found linux-6.18.55')

    def test_ambiguous_targets_are_rejected(self):
        self.add_kernel()
        self.add_kernel('target-aarch64_other_musl/linux-qualcommbe_ipq53xx')
        self.check(False, 'expected exactly one CS-06 target kernel; found:')

    def test_missing_target_config(self):
        kernel = self.add_kernel()
        (kernel / '.config').unlink()
        self.check(False, str(kernel / '.config'))

    def test_disabled_cma(self):
        kernel = self.add_kernel()
        (kernel / '.config').write_text(CONFIG.replace(
            'CONFIG_CMA=y', '# CONFIG_CMA is not set'))
        self.check(False, 'actual: # CONFIG_CMA is not set')

    def test_wrong_cma_selection_mode(self):
        kernel = self.add_kernel()
        (kernel / '.config').write_text(CONFIG.replace(
            'CONFIG_CMA_SIZE_SEL_MBYTES=y', 'CONFIG_CMA_SIZE_SEL_PERCENTAGE=y'))
        self.check(False, 'expected CONFIG_CMA_SIZE_SEL_MBYTES=y; actual: missing')

    def test_missing_compiled_kernel_release(self):
        kernel = self.add_kernel()
        release = kernel / 'include/config/kernel.release'
        release.unlink()
        self.check(False, str(release))

    def test_wrong_compiled_kernel_release(self):
        kernel = self.add_kernel()
        (kernel / 'include/config/kernel.release').write_text('6.18.55\n')
        self.check(False, 'expected compiled release 6.18.62')


if __name__ == '__main__':
    unittest.main()
