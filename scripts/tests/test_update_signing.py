import importlib.util
import json
import os
import shutil
import sys
import zipfile
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class UpdateSigningTests(unittest.TestCase):
    def test_signing_tool_exists(self):
        self.assertTrue((ROOT / 'scripts/sign-update.py').is_file())

    def test_public_export_blocks_pkcs8_private_keys(self):
        spec = importlib.util.spec_from_file_location('release_tools', ROOT / 'scripts/release_tools.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        self.assertIsNotNone(module.CREDENTIAL.search('-----BEGIN ' + 'PRIVATE KEY-----'))

    def test_archives_block_private_keys_ascii_and_utf16(self):
        spec = importlib.util.spec_from_file_location('package_tools', ROOT / 'scripts/package_tools.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            archive = Path(d) / 'private.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                for encoding in ['ascii', 'utf-16-le']:
                    z.writestr(encoding + '.pem', ('-----BEGIN ' + 'PRIVATE KEY-----').encode(encoding))
            self.assertEqual(len(module.scan_archive(archive)), 2)

    def test_binary_public_file_private_key_is_rejected(self):
        spec = importlib.util.spec_from_file_location('release_tools', ROOT / 'scripts/release_tools.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'README.md').write_text('hello')
            (root / 'LICENSE').write_text('MIT')
            (root / 'key.pem').write_text('-----BEGIN ' + 'PRIVATE KEY-----')
            (root / 'public-files.txt').write_text('README.md\nLICENSE\npublic-files.txt\nkey.pem\n')
            self.assertTrue(any('private key' in s for s in module.validate_tree(root)))

    @unittest.skipUnless(sys.platform == "darwin", "offline signing uses macOS system OpenSSL")
    def test_signed_manifest_binds_archive_version_and_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); key = root / 'key.pem'
            subprocess.run(['/usr/bin/openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(key)], check=True)
            key.chmod(0o600)
            toolroot = root / 'source'
            (toolroot / 'scripts').mkdir(parents=True); (toolroot / 'launcher-spec').mkdir()
            shutil.copyfile(ROOT / 'scripts/sign-update.py', toolroot / 'scripts/sign-update.py')
            public = subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'], check=True, capture_output=True).stdout
            import base64
            (toolroot / 'launcher-spec/update-public-key.txt').write_text(base64.b64encode(public).decode())
            archive = root / 'Sakura-0.2.0-preview.8-macOS.zip'; archive.write_bytes(b'archive fixture')
            p = subprocess.run(['python3', str(toolroot / 'scripts/sign-update.py'), '--key', str(key), '--version', '0.2.0-preview.8', '--platform', 'macOS', str(archive)], capture_output=True, env={**os.environ, "SAKURA_SIGNING_TEST": "1"})
            self.assertEqual(p.returncode, 0, p.stderr.decode())
            manifest = json.loads(archive.with_suffix('.zip.sig').read_text())
            self.assertEqual(manifest['version'], '0.2.0-preview.8')
            self.assertEqual(manifest['platform'], 'macOS')
            self.assertEqual(manifest['bytes'], 15)

            # A forgotten test environment variable must never bypass the trust root check.
            (toolroot / 'launcher-spec/update-public-key.txt').write_text('mismatched-public-key')
            p = subprocess.run(['python3', str(toolroot / 'scripts/sign-update.py'), '--key', str(key), '--version', '0.2.0-preview.8', '--platform', 'macOS', str(archive)], capture_output=True, env={**os.environ, "SAKURA_SIGNING_TEST": "1"})
            self.assertNotEqual(p.returncode, 0)
