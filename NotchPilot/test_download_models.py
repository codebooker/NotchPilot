import hashlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from download_models import install


class DownloadTests(unittest.TestCase):
    def manifest(self,data):
        return {'qwen':{'directory':'model','base_url':'https://example.invalid/',
            'files':[{'name':'model.bin','size':len(data),'sha256':hashlib.sha256(data).hexdigest()}]}}

    def test_verified_download_receipt_and_reuse(self):
        data=b'test model';manifest=self.manifest(data)
        with tempfile.TemporaryDirectory() as d,patch('download_models.emit'):
            root=Path(d);install(root,'qwen',manifest,lambda *a,**kw:io.BytesIO(data))
            self.assertEqual((root/'.cache/model/model.bin').read_bytes(),data)
            self.assertTrue((root/'.cache/model/.qwen-installed.json').exists())
            install(root,'qwen',manifest,lambda *a,**kw:self.fail('Verified files must not be downloaded again'))

    def test_corrupt_download_does_not_replace_existing_file_or_publish_receipt(self):
        with tempfile.TemporaryDirectory() as d,patch('download_models.emit'):
            root=Path(d);directory=root/'.cache/model';directory.mkdir(parents=True)
            (directory/'model.bin').write_bytes(b'old')
            with self.assertRaises(ValueError):install(root,'qwen',self.manifest(b'new'),lambda *a,**kw:io.BytesIO(b'bad'))
            self.assertEqual((directory/'model.bin').read_bytes(),b'old')
            self.assertFalse((directory/'.qwen-installed.json').exists())
            self.assertFalse((directory/'model.bin.download').exists())


if __name__=='__main__':unittest.main()
