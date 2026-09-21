import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import build


class SigningTests(unittest.TestCase):
    def test_selected_identity_is_persisted_across_discovery_order_changes(self):
        a='A'*40;b='B'*40
        with tempfile.TemporaryDirectory() as d,patch.object(build,'ROOT',Path(d)),patch.dict(os.environ,{},clear=True):
            with patch('build.subprocess.check_output',return_value=f'1) {a} "Apple Development: First"\n2) {b} "Apple Development: Second"'):
                self.assertEqual(build.signing_identity(),a)
            with patch('build.subprocess.check_output',return_value=f'1) {b} "Apple Development: Second"\n2) {a} "Apple Development: First"'):
                self.assertEqual(build.signing_identity(),a)

    def test_missing_saved_identity_does_not_silently_change_permissions_identity(self):
        with tempfile.TemporaryDirectory() as d,patch.object(build,'ROOT',Path(d)),patch.dict(os.environ,{},clear=True):
            saved=Path(d)/'.cache/notch-signing-identity';saved.parent.mkdir();saved.write_text('A'*40)
            with patch('build.subprocess.check_output',return_value='0 valid identities found'):
                with self.assertRaisesRegex(RuntimeError,'unavailable'):build.signing_identity()

    def test_explicit_identity_wins(self):
        with patch.dict(os.environ,{'NOTCHPILOT_SIGNING_IDENTITY':'explicit'}):
            self.assertEqual(build.signing_identity(),'explicit')


if __name__=='__main__':unittest.main()
