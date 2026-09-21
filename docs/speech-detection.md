# Speech-aware phrase detection

NotchPilot no longer uses microphone volume to decide whether a phrase begins or ends. It runs the locally bundled **Silero VAD v6.2.0** classifier on successive 32 ms, mono 16 kHz frames, then applies the user-selected one-, two-, or three-second pause before sending a completed phrase to Whisper.

The model remains loaded in a private local helper for the duration of the app session. Frames travel through stdin/stdout pipes; there is no network listener, cloud speech analysis, or retained audio. The waveform still responds to audio level because it is visual feedback only. It does not trigger a command.

The approximately 0.9 MB model is checked with a pinned SHA-256 checksum and downloads as part of **Download essentials**. Settings also lets you repair it independently. If it is missing or cannot start, NotchPilot stops clearly instead of falling back to a dB gate.

Silero VAD distinguishes speech-like audio from silence and many non-speech sounds better than a raw volume cut-off. It is **not** speaker recognition, wake-word detection, or a guarantee that nearby speech, television audio, or another person will be ignored. Use **Go to sleep** when the microphone should ignore ordinary speech.

## Validation in this build

The production helper classified one local spoken “Open Finder” replay into 60 frames. Its maximum speech probability was **0.99999**; 15 generated silence frames peaked at **0.0117**. This is a narrow replay sanity check, not a noisy-room, accessibility, or speaker-separation benchmark.

Native tests cover the state machine after VAD decisions, phrase-pause behavior, overflow, cancellation, and continuous resampling from 48 kHz to 16 kHz. The model is also exercised through its real binary protocol. Run the reproducible check with:

```sh
python3 NotchPilot/experiments/eval_vad_session.py \
  --session NotchPilot/build/NotchPilot.app/Contents/Resources/vad-session \
  --model .cache/vad-models/ggml-silero-v6.2.0.bin \
  --audio NotchPilot/build/speech-replay/utterance-0.wav \
  --output /tmp/vad-results.json
```

The implementation uses the VAD API and model delivery path documented by [whisper.cpp](https://github.com/ggml-org/whisper.cpp#voice-activity-detection-vad). Recheck the upstream model terms before distributing a standalone installer.

## Quieter voices (experimental, off by default)

Each completed phrase gets a level in dBFS, measured over its speech frames only so the closing pause does not dilute it. After three phrases, **Ignore quieter voices** drops any phrase more than 12 dB below the median of your recent accepted phrases, before transcription. Only accepted phrases are learned. This is a loudness heuristic: it cannot tell who is speaking, and it has only been checked with synthetic levels, not real rooms.
