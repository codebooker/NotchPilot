"""User-triggered model downloads with pinned checksums and atomic file replacement."""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request
from pathlib import Path


def emit(**event):print(json.dumps(event),flush=True)


def matches(path,spec):
    if not path.is_file() or path.stat().st_size!=spec['size']:return False
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(4*1024*1024),b''):digest.update(chunk)
    return digest.hexdigest()==spec['sha256']


def install(root,name,manifest,opener=urllib.request.urlopen):
    model=manifest[name];directory=root/'.cache'/model['directory'];directory.mkdir(parents=True,exist_ok=True)
    total=sum(spec['size'] for spec in model['files']);complete=0
    # Receipt is published only after every file has been verified.
    receipt=directory/('.'+name+'-installed.json')
    receipt.unlink(missing_ok=True)
    emit(event='progress',text='Checking local files',progress=0)
    for spec in model['files']:
        if Path(spec['name']).name!=spec['name']:raise ValueError('Invalid model filename')
        path=directory/spec['name']
        if matches(path,spec):
            complete+=spec['size'];emit(event='progress',text='Verified '+spec['name'],progress=complete/total);continue
        partial=path.with_name(path.name+'.download');read=0;last=0
        try:
            with opener(model['base_url']+spec['name'],timeout=30) as response,partial.open('wb') as out:
                while chunk:=response.read(1024*1024):
                    out.write(chunk);read+=len(chunk)
                    if read>spec['size']:raise ValueError('Model size mismatch')
                    if time.monotonic()-last>.2:
                        emit(event='progress',text='Downloading '+spec['name'],progress=(complete+read)/total);last=time.monotonic()
            if not matches(partial,spec):raise ValueError('Model checksum mismatch')
            os.replace(partial,path)
        finally:partial.unlink(missing_ok=True)
        complete+=spec['size']
    temporary=receipt.with_suffix('.tmp');temporary.write_text(json.dumps(model));os.replace(temporary,receipt)
    emit(event='done',text=('Qwen3 1.7B' if name=='qwen' else 'Whisper base.en')+' installed and verified.',progress=1)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--model',choices=['qwen','whisper'],required=True);args=parser.parse_args()
    manifest=json.loads(Path(__file__).with_name('models.json').read_text())
    install(args.root,args.model,manifest)


if __name__=='__main__':
    try:main()
    except Exception as e:
        emit(event='error',text='Download failed ('+type(e).__name__+'). Check your connection and try again.')
        sys.exit(1)
