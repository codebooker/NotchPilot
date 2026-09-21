# Testing NotchPilot

See [Hands-free use and validation](hands-free.md) for persistent speech, corrections, sleep/wake, and the new TextEdit Save As recovery route. The older reports below describe the behavior before that route.

See the [latest regression report](regressions-2026-09-21.md) for ten live trials, the fixes they informed, and remaining Save As limitations.

See the [dictation regression report](dictation-regression.md) for the open-document writing fix, caret/selection tests, and speech-replay limits.

## Model-free Python checks

On macOS, after the full setup:

```sh
.cache/notch-venv/bin/python -B -m unittest discover -s NotchPilot -p 'test_*.py'
```

Or install only test dependencies in a fresh Python 3.12 environment:

```sh
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python -r requirements-test.txt
.venv/bin/python -B -m unittest discover -s NotchPilot -p 'test_*.py'
```

The current suite has **111 tests**. They cover request validation, navigation verification, command ordering and stage budgets, unreadable-window recovery, fresh element tokens, cancellation/checkpoints, model download integrity, signing identity stability, and experimental adapter behavior. API responses and desktop input are mocked. No API key or model download is required for these checks.

Files named `test_flight_live.py` and `test_recipe_live.py` are explicit manual runners, not unittest cases. Do not launch them as ordinary unit tests: they control apps and can incur API usage. The flight example also contains fixed example dates that must be updated before a relevant live test.

## Native voice checks

```sh
mkdir -p NotchPilot/build
swiftc -swift-version 5 -parse-as-library \
  NotchPilot/Sources/VoiceCore.swift NotchPilot/Sources/SpeechCapture.swift \
  NotchPilot/Tests/VoiceTests.swift -o NotchPilot/build/voice-tests \
  -framework AVFoundation
NotchPilot/build/voice-tests
```

These exercise silence, all three phrase delays, mid-phrase delay changes, continuous utterances, overflow recovery, ordered queues, session phrases, and audio resampling. They do not record from your microphone.

## Native session checks

Run these on a Mac with an interactive desktop session; they exercise native window and cursor behavior with synthetic capture state:

```sh
mkdir -p NotchPilot/build
swiftc -swift-version 5 -D SESSION_TESTS -parse-as-library \
  NotchPilot/Sources/*.swift NotchPilot/Tests/SessionTests.swift \
  -o NotchPilot/build/session-tests \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework Carbon -framework ApplicationServices -framework Security \
  -framework ScreenCaptureKit
NotchPilot/build/session-tests
```

Tests cover recognizer timeout/cancellation, dictation command parsing, unique Unicode selection ranges, continuous voice recovery, auto-close, draft/queue handling, review pause/resume, closing a paused worker, stale callbacks, exact input guards, and cursor timing/edge placement. The app’s global keyboard implementation intentionally avoids an all-key event monitor, which previously caused doubled physical keystrokes.

For a rendered cursor preview:

```sh
NotchPilot/build/session-tests --cursor-preview /tmp/notchpilot-cursor.png
```

## Local interpreter evaluation

After downloading Qwen in the app:

```sh
.cache/notch-venv/bin/python -B NotchPilot/eval_planner.py
```

This is a separate local-model evaluation. The development snapshot passed 20/20 included cases; that small suite is not evidence of general natural-language reliability.

## Live desktop checks

Use disposable documents and public sample URLs. Confirm results in the target app, rather than relying only on a “done” message.

| Check | Look for |
|---|---|
| Open/close with hotkey | Mic becomes active; the second press stops capture and work. |
| Calculator 6 × 7 | Visible expression and result 42; no duplicate or stale clicks. |
| New Chrome tab → example.com | One additional tab, same browser window, loaded destination. |
| Short app chain | Apps come forward in the requested order. |
| TextEdit disposable file | Exact content and an actual saved result. |
| Review while working | Pause before the editor takes focus; correct queued text; safe resume. |
| Cancel while paused | Worker exits, no later input, microphone remains available. |
| Dark / Light / System | Legible fields/buttons, native title bars, persisted selection. |
| Physical typing while open | One character per physical keypress. |

The published code was exercised in these categories during development, with both successful and failed runs. Known remaining failures include longer model-driven chains, custom attached dialogs, and Finder location verification when macOS exposes an unresolvable file-reference URL. A roughly 13-second local Calculator smoke run was observed on the development Mac; it is not a cross-machine performance promise.

CI runs Python tests, Swift typechecking, and native voice checks. It does not test live microphone capture, macOS permission prompts, paid API responses, or arbitrary desktop workflows.

## Persistent Whisper replay

The [recorded comparison](../NotchPilot/experiments/results/whisper-session.json) used one local “Open Finder” test recording with base.en: 108 ms helper startup, 46 ms median warm transcription, and 168 ms median per-process CLI transcription. The first persistent transcription took 67 ms. All recognized the phrase; an invalid-file request returned an error and the next valid request succeeded. This excludes microphone endpointing and desktop execution and does not establish a general app speedup.

With setup complete and your own mono 16 kHz WAV:

```sh
python3 NotchPilot/experiments/eval_whisper_session.py \
  --session NotchPilot/build/NotchPilot.app/Contents/Resources/whisper-session \
  --cli .cache/whisper.cpp/build/bin/whisper-cli \
  --model .cache/whisper-models/ggml-base.en.bin \
  --audio /path/to/test.wav --output /tmp/whisper-results.json
```

The helper uses the pinned CLI's optimized flash-attention setting. The app prewarms it when the speech model is installed. The cursor test now uses the same transparent window factory as the app and checks zero-alpha corners in its rendered bitmap. This fixes an opaque gray test-window background that appeared during live test runs.

Native session tests separately check that cancelled callbacks stay silent and a nonresponding helper times out once.

## S1 Forms

See the [S1 evaluation](cua-s1-evaluation.md) for source/model pins, 60 fictional decisions, CPU timings, upstream tests, and a separate browser delivery smoke that verified only six of eight fields. It is not included in the ordinary unit suite or default runtime.
