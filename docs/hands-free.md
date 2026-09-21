# Keep talking. Keep your place.

NotchPilot now has an explicit dictation mode, local correction commands, and native Save As recovery. The familiar inspiration is **Dragon NaturallySpeaking**: a clear distinction between writing words and controlling the computer. This is a first implementation, not Dragon feature parity.

## A conversation to try

Open a disposable TextEdit document and press your NotchPilot hotkey:

```text
Start dictating.
A little boy rode his purple bike.
It had flames on it.
Replace purple with blue.
New paragraph.
This is a second paragraph.
Scratch that.
Save as My first note on my desktop.
Done dictating.
Open Safari.
```

Pause between phrases using your chosen one-, two-, or three-second delay. You do not need to repeat “write” before each sentence, close the microphone, or click a send button. In dictation mode, ordinary phrases become text. The strip says **Dictating**, and automatic closing is suspended until you leave that mode.

## Words that work locally

| Say | Result |
|---|---|
| **Start dictating** / **Start dictation** | Bind dictation to the current document window. |
| **Done dictating** / **Command mode** | Return to interpreting requests as computer tasks. |
| **New line** / **New paragraph** | Insert one or two line breaks. |
| **Select purple bike** | Select a unique matching phrase, ignoring case. |
| **Replace purple with blue** / **Change purple to blue** | Replace a unique phrase and verify the resulting text. |
| **Scratch that** | Reverse the last recorded dictation edit, if the document still matches its result. |
| **Go to beginning** / **Go to end** | Move the caret to the document boundary. |
| **Type exactly …** / **Literal text …** | Insert the remaining transcript literally, including command-like words. |
| **Next field** / **Previous field** | Tab / Shift–Tab in the current window. |
| **Press enter**, **Move left/right/up/down** | Send the corresponding key. |
| **Page up/down** / **Scroll up/down** | Send a page-navigation key; behavior depends on the focused app. |
| **Open TextEdit/Safari/Finder/Calculator/Google Chrome/Notes/Mail** | Open or activate that app directly and leave dictation mode. “Switch to” and “Launch” also work. |
| **Save as My note on my desktop** | Save a new copy to Desktop, keeping the document's extension if the dialog exposes it. |
| **Save as My note.rtf in my documents** | Save a new copy to Documents. |
| **Save as ~/Desktop/My note.rtf** | Use an explicit destination path. |
| **Go to sleep** / **Pause listening** | Ignore ordinary speech until **Wake up** / **Resume listening**. The mic remains on to hear the wake phrase. |
| **What can I say?** | Open the built-in voice-command guide. |
| **Cancel that** | Cancel work and waiting requests, keeping the microphone available. Completed changes remain. |
| **Stop**, hotkey, Escape, or × | End the session and stop capture. Spoken commands take effect after transcription. |

These routes do not call an online model. Other app requests still use the configured interpreter/controller. Literal mode preserves the *transcript*; it cannot undo a speech recognition mistake. Command phrases are reserved during dictation: say “literal text new paragraph” if those words belong in your document.

## Corrections preserve the document

Insertion uses the editor's observed accessibility selection, checks the exact foreground app/window, and verifies the resulting whole text. It keeps existing text outside the selection. Corrections refuse missing or repeated matches; give a longer unique phrase to resolve ambiguity.

“Scratch that” uses a bounded, in-memory history of the last 20 edits. It checks the document, field, and full text before undoing. A manual edit, different document, or changed contents prevents an automatic undo. It does not invoke the app's arbitrary undo stack, restore earlier sessions, or rewrite the entire document as plain text.

## Save As recovery

The native route handles TextEdit's standard Save As dialog, including a dialog that is already open. It sets the name and destination, avoids also saving changes back to the original when that option is present, and clicks Save once. Success requires both a file at the requested path and a matching document URL exposed by the app.

Existing destinations are refused. Choose another name; NotchPilot does not approve replacement prompts. The destination folder must already exist. A filename without an extension inherits the extension shown in the dialog when available. This is not format conversion: asking an RTF document to become `.txt` can introduce an unsupported format prompt.

Custom save dialogs, editors without readable selections, and documents with multiple ambiguous text areas still need work. Direct corrections inspect at most 200,000 UTF-16 code units. The app reports a limitation instead of claiming an unverified save or correction.

## Persistent speech, bounded work

A signed helper loads Whisper **base.en** once and stays resident. Requests travel over private stdin/stdout pipes, with no HTTP listener. Each phrase is decoded independently, so “persistent” refers to loaded weights rather than a growing transcript prompt. Temporary WAVs are removed after use or cancellation. Cancelled request IDs cannot return text to the editor; a 90-second request timeout resets a stuck helper.

Dictation remains active across pauses. An individual unbroken phrase may last up to 120 seconds; command mode retains its 30-second bound. Overlong phrases are discarded through the next pause rather than executed partially. This is phrase-based dictation, not live partial-word streaming. Segmentation still uses audio energy and the selected pause duration; neural voice detection and personalized vocabulary are future work.

## Verified in this development pass

- Live TextEdit: multiple phrases, new paragraph, unique selection/replacement, punctuation on correction commands, and scratch restoration.
- Sleep ignored a test sentence and wake resumed the same dictation mode.
- Scratch refused after an intervening manual edit, preserving both edits.
- Save As worked from an existing dialog and from the document; a missing extension became `.rtf`. Saved contents were independently read back.
- An existing destination was refused and its SHA-256 remained unchanged.
- Native tests cover cancellation, timeout, queues, mode commands, selection ranges, Unicode offsets, and long phrase segmentation.

**Background-speech limitation:** during the live-microphone session, unrelated ambient speech was also inserted into the disposable document. The session was stopped and the fixture restored. There is no speaker identification or media-speech rejection; use sleep mode when other speech should be ignored.

The controlled desktop trials submitted transcripts through the app's typed command field. The same instruction handler accepts microphone transcripts, but these trials are not a substitute for testing real microphones, accents, speech impairments, or noisy rooms. A separate base.en audio replay verified persistent recognition and invalid-file recovery. See [Testing](testing.md).

Next useful additions: spoken feedback that cannot trigger its own microphone, numbered control overlays, a spelling/vocabulary mode, and real-user accessibility trials. These are not implemented yet.
