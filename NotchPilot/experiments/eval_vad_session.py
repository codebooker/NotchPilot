"""Exercise the bundled streaming Silero VAD protocol against a 16 kHz WAV."""
import argparse
import json
import struct
import subprocess
import wave
from pathlib import Path

FRAME = 512


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with wave.open(str(args.audio), "rb") as source:
        if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (16000, 1, 2):
            raise ValueError("Use a mono 16 kHz 16-bit WAV")
        samples = [sample[0] / 32768 for sample in struct.iter_unpack("<h", source.readframes(source.getnframes()))]
    with subprocess.Popen([str(args.session), str(args.model)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        if process.stdout.readline() != b'{"event":"ready"}\n':
            raise RuntimeError("VAD helper did not become ready")

        def score(frame):
            process.stdin.write(b"F" + struct.pack("<512f", *frame))
            process.stdin.flush()
            return struct.unpack("<f", process.stdout.read(4))[0]

        speech = [score((samples[start:start + FRAME] + [0] * FRAME)[:FRAME]) for start in range(0, len(samples), FRAME)]
        silence = [score([0] * FRAME) for _ in range(15)]
        process.stdin.close()
        process.wait(timeout=10)
    result = {
        "scope": "One supplied speech recording and generated digital silence; classifier only",
        "speech_frames": len(speech),
        "speech_min": min(speech), "speech_max": max(speech), "speech_mean": sum(speech) / len(speech),
        "silence_max": max(silence), "silence_mean": sum(silence) / len(silence),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if result["speech_max"] < .5 or result["silence_max"] >= .5:
        raise SystemExit("Unexpected speech/silence separation")


if __name__ == "__main__":
    main()
