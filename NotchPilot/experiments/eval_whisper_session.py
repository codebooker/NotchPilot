"""Compare persistent and per-phrase base.en using the same supplied test recording."""
import argparse,json,subprocess,time
from pathlib import Path


def main():
    parser=argparse.ArgumentParser()
    for name in ('session','cli','model','audio','output'):parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();rows=[]
    start=time.perf_counter()
    with subprocess.Popen([str(args.session.resolve()),str(args.model.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True) as process:
        assert json.loads(process.stdout.readline())['event']=='ready'
        load=time.perf_counter()-start
        for i in range(4):
            start=time.perf_counter();process.stdin.write(json.dumps({'id':str(i),'path':str(args.audio.resolve())})+'\n');process.stdin.flush()
            result=json.loads(process.stdout.readline());assert result['event']=='transcript' and result['id']==str(i)
            rows.append({**result,'wall_seconds':time.perf_counter()-start})
        # An invalid file must produce an error, then leave the loaded process usable.
        process.stdin.write(json.dumps({'id':'invalid','path':'/nonexistent/notchpilot-test.wav'})+'\n');process.stdin.flush()
        assert json.loads(process.stdout.readline())['event']=='error'
        process.stdin.write(json.dumps({'id':'recovery','path':str(args.audio.resolve())})+'\n');process.stdin.flush()
        recovery=json.loads(process.stdout.readline());assert recovery['event']=='transcript'
        process.stdin.close();process.wait(timeout=10)
    baseline=[]
    for _ in range(3):
        start=time.perf_counter();result=subprocess.run([str(args.cli.resolve()),'-m',str(args.model.resolve()),'-f',str(args.audio.resolve()),'-l','en','-nt','-np','-t','4','--prompt','Voice commands for a Mac. Open TextEdit. Write a sentence. Type hello world.'],capture_output=True,text=True,check=True,timeout=90)
        baseline.append({'seconds':time.perf_counter()-start,'text':result.stdout.strip()})
    output=dict(scope='One test recording; excludes microphone endpointing and action execution',startup_seconds=load,persistent=rows,cli=baseline,error_recovery=True)
    args.output.write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output,indent=2))
if __name__=='__main__':main()
