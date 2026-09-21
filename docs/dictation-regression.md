# Open-document dictation regression

## Reproduced failures

- “Write a little boy rode his bike. It was purple and had flames on it.” triggered an ambiguous-reference question. The interpreter treated “it” inside the dictated sentence as an object reference, even with an empty editor open.
- Follow-up workers did not receive the active document window, so they could choose an app again instead of using the existing editor.
- Model-driven text entry could choose Select All or concatenate a new sentence directly after the preceding period. The Select All attempt was stopped during testing before any replacement.

## Changes

- Recognize conservative literal writing requests before local model interpretation. Preserve words such as “it,” “this,” and “then” as dictated content. Composition and compound tasks remain interpreter requests.
- Carry the active process and window identity into the worker and verify that the window still exists. Freeze that target through interpretation; do not fall back to a different document when it closes.
- When one document text area is observed, insert literal text locally through the signed host using the actual selection. Check focus, window, selection bounds, and the resulting value; do not retry partially applied input. Explicitly selected text can be replaced, but the controller cannot select all for ordinary dictation.
- Add spacing at word boundaries for ordinary dictation. “Type exactly” preserves literal spacing. Mid-word insertion and selection replacement retain their positions.
- Give Whisper a brief command-vocabulary prompt to help distinguish “write” from “right.”

## Verification

- **111 Python tests pass**, covering literal recognition, model bypass, retained window identity, closed/invalid targets, explicit app changes, preview behavior, exact text, and the existing controller suite.
- Native session tests pass, including empty text, appending, existing whitespace, mid-word insertion, selected-word replacement, exact spacing, Unicode offsets, and invalid ranges.
- Signed build verification passes with the existing identity and permissions.
- Live TextEdit: ordinary writing inserted the requested sentence into the open document. Two successive final-build requests preserved the existing text and inserted natural separating spaces. A final request beginning “Write This…” also succeeded in an empty test editor.
- Those three final-build dictation runs took **1.038, 1.109, and 1.172 seconds** in the worker, each with **$0 model cost**. These are local smoke timings and exclude speech recognition, app startup, and interpretation startup.
- An audio replay through installed Whisper base.en originally transcribed “Write” as “Right.” The command prompt corrected that word in this fixture, but another word still had a transcription error. This is not a physical-microphone or general speech-accuracy claim.

## Scope

Validated live in TextEdit. Other editors must expose usable accessibility text and selection attributes. This is literal command-based dictation, not an always-on free-dictation mode: begin each writing request with “write” or “type.” Generating a story, email, or other new prose remains separate from entering supplied words and uses the existing composition setting. No sending or saving was added to dictation.
