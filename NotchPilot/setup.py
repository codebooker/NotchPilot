"""Prepare pinned local runtimes, then build NotchPilot. No API calls or keys needed."""
import shutil
import subprocess
from pathlib import Path

from build import HERE, runtime_root

ROOT=runtime_root()
CACHE=ROOT/'.cache'
REPOS={
    'jev-ultrafast':('https://github.com/browser-use/jev-ultrafast.git','1231850a0bf1a0c0341fe408ef1668dbbfdfac46'),
    'typesafe-computer-use':('https://github.com/awlevin/typesafe-computer-use.git','cc7b5066ae1a07b5e3182e8f87a9b5b6dfdcffc1'),
    'whisper.cpp':('https://github.com/ggml-org/whisper.cpp.git','5670d5c0bbcb148feabef84400a07cfca9aa3b30')}


def run(args):subprocess.run([str(x) for x in args],check=True)


def main():
    CACHE.mkdir(exist_ok=True)
    for name,(url,commit) in REPOS.items():
        path=CACHE/name
        if not path.exists():
            run(['git','init',path]);run(['git','-C',path,'remote','add','origin',url])
            run(['git','-C',path,'fetch','--depth','1','origin',commit]);run(['git','-C',path,'checkout','--detach',commit])
        actual=subprocess.check_output(['git','-C',str(path),'rev-parse','HEAD'],text=True).strip()
        if actual!=commit:raise RuntimeError('Existing cache has a different revision: '+name)
    uv=shutil.which('uv') or str(Path.home()/'.local/bin/uv')
    python=CACHE/'notch-venv/bin/python'
    if not python.exists():run([uv,'venv',CACHE/'notch-venv','--python','3.12'])
    run([uv,'pip','install','--python',python,CACHE/'typesafe-computer-use',CACHE/'jev-ultrafast','httpx==0.28.1','python-dotenv==1.2.3','mlx-lm==0.31.3','cua-driver==0.28.2'])
    whisper=CACHE/'whisper.cpp'
    run(['cmake','-S',whisper,'-B',whisper/'build','-DCMAKE_BUILD_TYPE=Release','-DWHISPER_BUILD_TESTS=OFF','-DWHISPER_BUILD_SERVER=OFF'])
    run(['cmake','--build',whisper/'build','--config','Release','-j','6','--target','whisper-cli'])
    # Model weights are downloaded by the user from Settings after launch.
    run([python,HERE/'build.py'])


if __name__=='__main__':main()
