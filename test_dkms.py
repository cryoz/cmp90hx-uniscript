"""Offline DKMS integration checks. No /usr/src, module or service mutations."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SCRIPT = (ROOT / 'unlock_cmp90hx.sh').read_text()
DEFS = re.sub(r'^readonly SCRIPT_DIR=.*$', f'readonly SCRIPT_DIR="{ROOT}"',
              SCRIPT.rsplit('\ncase "$ACTION" in', 1)[0], flags=re.M)


class DkmsTests(unittest.TestCase):
    def generate(self, directory):
        result = subprocess.run(['bash', '-c', DEFS + '\nwrite_dkms_build_script "$TEST_DIR"'],
                                env=dict(os.environ, TEST_DIR=str(directory)),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_scripts_syntax(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.generate(tmp)
            for name in ('cmp90-build.sh', 'cmp90-post-install.sh', 'dkms.conf'):
                subprocess.run(['bash', '-n', str(Path(tmp) / name)], check=True)
            # Real DKMS variable expansion must retain the future target kernel.
            cmd = 'kernelver=6.18.99-future; kernel_source_dir=/headers/future; parallel_jobs=3; source "$1"; printf "%s" "${MAKE[0]}"'
            result = subprocess.run(['bash', '-c', cmd, 'test', str(Path(tmp) / 'dkms.conf')],
                                    capture_output=True, text=True, check=True)
            self.assertIn("'6.18.99-future' '/headers/future' '3'", result.stdout)
            # DKMS 3.0 executes POST_INSTALL by word splitting, not eval;
            # quotes around the kernel would become part of the argument.
            cmd = 'kernelver=6.18.99-future; kernel_source_dir=/headers/future; parallel_jobs=3; source "$1"; printf "%s" "$POST_INSTALL"'
            result = subprocess.run(['bash', '-c', cmd, 'test', str(Path(tmp) / 'dkms.conf')],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, 'cmp90-post-install.sh 6.18.99-future')

    def test_offline_build_targets_future_kernel(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            self.generate(base)
            headers = base / 'headers'
            headers.mkdir()
            (headers / '.config').write_text('CONFIG_GCC_VERSION=150200\n')
            (base / 'kernel-open').mkdir()
            (base / 'kernel-open/nvidia.ko').write_text('GEN2CHAIN')
            (base / 'kernel-open/nvidia-uvm.ko').write_text('uvm')
            (base / 'compat-dkms.sh').write_text('fix_kernel_compat() { :; }\n')
            binary = base / 'bin'
            binary.mkdir()
            for name, body in {
                'gcc-15': 'exit 0',
                'make': 'printf "%s\\n" "$*" >>"$TEST_LOG"',
                'modinfo': 'echo "$TEST_TARGET SMP preempt mod_unload"',
            }.items():
                path = binary / name
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'],
                       TEST_LOG=str(base / 'make.log'), TEST_TARGET='6.18.99-future')
            result = subprocess.run(['bash', str(base / 'cmp90-build.sh'), env['TEST_TARGET'],
                                     str(headers), '3'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (base / 'make.log').read_text().splitlines()
            self.assertEqual(len(calls), 3)
            self.assertTrue(all(f'SYSSRC={headers}' in call and f'SYSOUT={headers}' in call
                                for call in calls))
            # Reject a module built for another kernel, even if make succeeds.
            (binary / 'modinfo').write_text('#!/bin/sh\necho "6.18.1-wrong SMP"\n')
            result = subprocess.run(['bash', str(base / 'cmp90-build.sh'), env['TEST_TARGET'],
                                     str(headers)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Wrong vermagic', result.stderr)

    def test_compressed_module_resolution_and_stock_rejection(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'nvidia.ko.zst'
            path.touch()
            body = '''
modinfo() { if [[ "$1" == -p ]]; then echo "$PARAMS"; else echo "$MODULE"; fi; }
patched_module_path
'''
            env = dict(os.environ, MODULE=str(path), PARAMS='cmp90_gen2_idx:Gen2 index (uint)')
            result = subprocess.run(['bash', '-c', DEFS + body], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(path))
            env['PARAMS'] = 'NVreg_ResmanDebugLevel:int'
            result = subprocess.run(['bash', '-c', DEFS + body], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_migration_build_and_install_failures_preserve_manual_modules(self):
        for state, build_fail, install_fail in [('added', '1', '0'), ('built', '0', '1')]:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                old = root / 'manual'
                old.mkdir()
                (old / 'nvidia.ko').write_text('original-module')
                source = root / 'usr-src/cmp90hx-nvidia-610.43.03-gen2.1'
                source.mkdir(parents=True)
                (source / 'cmp90-upstream-ref').write_text('c94505635a2ef6883678b990a7dd9e4efe15ed0d\n')
                defs = DEFS.replace('/usr/src/', str(root / 'usr-src') + '/')
                defs = defs.replace('/lib/modules/$(uname -r)/updates/cmpunlocker-90hx-stockflow',
                                    str(old))
                mocks = '''
dkms_preflight() { :; }
depmod() { :; }
dkms() {
    case "$1" in
        status) echo "cmp90hx-nvidia/610.43.03-gen2.1: $TEST_STATE" ;;
        build) return "$BUILD_FAIL" ;;
        install) echo INSTALL_ATTEMPT; return "$INSTALL_FAIL" ;;
        *) return 99 ;;
    esac
}
install_dkms_modules unused
'''
                env = dict(os.environ, TEST_STATE=state, BUILD_FAIL=build_fail,
                           INSTALL_FAIL=install_fail, CMP90_STATE_DIR=str(root / 'state'))
                result = subprocess.run(['bash', '-c', defs + mocks], env=env,
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((old / 'nvidia.ko').read_text(), 'original-module')
                if build_fail == '1':
                    self.assertNotIn('INSTALL_ATTEMPT', result.stdout)

    def test_split_actual_pinned_upstream(self):
        upstream = os.environ.get('CMP90_TEST_UPSTREAM')
        if not upstream:
            self.skipTest('set CMP90_TEST_UPSTREAM to a pinned Rhonstin checkout')
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / 'driver'
            driver.mkdir()
            shutil.copyfile(Path(upstream) / 'driver/build-gen2.sh', driver / 'build-gen2.sh')
            result = subprocess.run(['bash', '-c', DEFS + '\nprepare_dkms_scripts "$TEST_DIR"'],
                                    env=dict(os.environ, TEST_DIR=tmp), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ('prepare-dkms.sh', 'compat-dkms.sh'):
                subprocess.run(['bash', '-n', str(driver / name)], check=True)
            prepare = (driver / 'prepare-dkms.sh').read_text()
            self.assertIn('patch -p1', prepare)
            self.assertNotIn('mkdir -p "${INSTALL_MOD_DIR}"', prepare)
            self.assertNotIn('modprobe -r', prepare)

    def test_real_source_preparation(self):
        upstream = os.environ.get('CMP90_TEST_UPSTREAM')
        archive = os.environ.get('CMP90_TEST_NVIDIA_ARCHIVE')
        if not upstream or not archive:
            self.skipTest('set CMP90_TEST_UPSTREAM and CMP90_TEST_NVIDIA_ARCHIVE')
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / 'driver'
            shutil.copytree(Path(upstream) / 'driver', driver, ignore=shutil.ignore_patterns('.build'))
            (driver / 'VERSION').write_text('610.43.03\n')
            cache = driver / '.build'
            cache.mkdir()
            shutil.copyfile(archive, cache / 'open-gpu-kernel-modules-610.43.03.tar.gz')
            result = subprocess.run(['bash', '-c', DEFS + '\nprepare_dkms_scripts "$TEST_DIR"'],
                                    env=dict(os.environ, TEST_DIR=tmp), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(['bash', str(driver / 'prepare-dkms.sh')],
                                    env=dict(os.environ, CMPUNLOCKER_CARD_PROFILE='cmp90-rejoin15'),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-4000:])
            source = cache / 'open-gpu-kernel-modules-610.43.03'
            hook = (source / 'src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_booter_tu102.c').read_text()
            self.assertTrue('GEN2CHAIN' in hook, 'Missing Gen2 hook in actual patched sources')
            self.assertTrue('"CMP90_STOCKFLOW_REJOIN16:' not in hook,
                            'Old Gen2 runtime diagnostics remain (comments are harmless)')
            self.assertFalse((source / 'kernel-open/nvidia.ko').exists())


if __name__ == '__main__':
    unittest.main()
