"""Measure how the whisper-session prompt affects dictation continuity, vocabulary, and noise.

macOS only: clips are synthesized with `say` (Samantha) and system sounds, then decoded by the
resident helper with and without a prompt. Synthesized speech is a sanity check, not a substitute
for real microphones, accents, or rooms.
"""
import argparse
import json
import math
import random
import struct
import subprocess
import tempfile
import uuid
import wave
from pathlib import Path

SPEECH = {'part1': 'A little boy rode his', 'part2': 'purple bike', 'vocab': 'Open notch pilot settings and check kubernetes',
          'spell': 'spell c a t', 'number': 'five', 'keys': 'press command shift s'}
CASES = [('part1', True, ''), ('part2', True, ''), ('part2', True, 'A little boy rode his'),
         ('vocab', False, None), ('vocab', False, 'Voice commands for a Mac. Open TextEdit. Write a sentence. Type hello world. Vocabulary: NotchPilot, Kubernetes.'),
         ('vocab', True, 'NotchPilot, Kubernetes.'), ('spell', False, None), ('number', False, None), ('keys', False, None)]
NOISE = ['silence', 'whitenoise', 'burst', 'hum', 'clicks', 'breath', 'Tink', 'Pop', 'Basso', 'Glass']


def write(path, samples):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(b''.join(struct.pack('<h', max(-32767, min(32767, int(s)))) for s in samples))


def synthesize(folder):
    rate = 16000; random.seed(7)
    for name, text in SPEECH.items():
        subprocess.run(['say', '-v', 'Samantha', '-o', str(folder/f'{name}.aiff'), text], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(folder/f'{name}.aiff'), str(folder/f'{name}.wav')], check=True)
    write(folder/'silence.wav', [0]*rate)
    write(folder/'whitenoise.wav', [random.gauss(0, 1500) for _ in range(rate)])
    write(folder/'burst.wav', [0]*int(rate*.6)+[random.gauss(0, 6000)*math.exp(-i/1500) for i in range(int(rate*.3))]+[0]*int(rate*.8))
    write(folder/'hum.wav', [3000*math.sin(2*math.pi*110*i/rate) for i in range(rate*2)])
    write(folder/'clicks.wav', [(8000 if i % 2400 < 30 else 0)*random.choice([1, -1]) for i in range(rate*2)])
    write(folder/'breath.wav', [random.gauss(0, 900)*math.sin(math.pi*i/(rate*1.2)) for i in range(int(rate*1.2))]+[0]*int(rate*.5))
    for sound in NOISE[6:]:
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', f'/System/Library/Sounds/{sound}.aiff', str(folder/f'{sound}.wav')], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--session', required=True); parser.add_argument('--model', required=True); parser.add_argument('--output', required=True)
    args = parser.parse_args()
    helper = subprocess.Popen([args.session, args.model], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    assert json.loads(helper.stdout.readline())['event'] == 'ready'
    results = []
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory); synthesize(folder)
        for clip, dictation, prompt in CASES + [(n, True, '') for n in NOISE] + [(n, False, None) for n in NOISE]:
            request = {'id': str(uuid.uuid4()), 'path': str(folder/f'{clip}.wav'), 'dictation': dictation}
            if prompt is not None: request['prompt'] = prompt
            helper.stdin.write(json.dumps(request)+'\n'); helper.stdin.flush()
            reply = json.loads(helper.stdout.readline())
            results.append({'clip': clip, 'dictation': dictation, 'prompt': prompt, 'text': reply.get('text', '').strip(),
                            'confidence': round(reply.get('confidence', 0), 3), 'no_speech': round(reply.get('no_speech', 0), 3)})
            print(f"{clip:10} dictation={dictation!s:5} prompt={(prompt or '')[:30]!r:34} -> {results[-1]['text']!r}")
    helper.stdin.close(); helper.wait()
    Path(args.output).write_text(json.dumps(results, indent=2)+'\n')


if __name__ == '__main__':
    main()
