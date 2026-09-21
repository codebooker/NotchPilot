# Troubleshooting

## The app says a permission is missing

Open **Settings → Setup** and use the matching Allow button. Enable NotchPilot for Microphone, Accessibility, and Screen Recording in macOS settings. Then choose **I’ve enabled them — check again**. A Screen Recording change can require quitting and reopening the app.

If a rebuilt app still appears enabled but reports denied access, check signing first. The build uses a saved Apple Development identity when available. Ad-hoc builds can invalidate prior grants after code changes. Do not reset every app’s permissions; repair only NotchPilot’s stale entry if needed.

## The hotkey opens something else

Go to **Everyday → Your shortcut → Change** and choose another combination. Control–Option–Space is the default. Escape cancels shortcut recording; a rejected combination leaves the previous one active.

## It cuts me off, or I need longer to think

Choose **Everyday → Time to finish speaking → Relaxed** or **Unhurried**. These wait two or three seconds after speech. The setting applies to the next phrase without restarting the microphone. Continuous phrases longer than 30 seconds are discarded, so break a long request into shorter instructions.

## It is doing the wrong thing

Press **Escape** or the hotkey for an immediate full stop. “Cancel that” keeps the microphone ready for another request, but spoken controls take effect after transcription. Cancellation prevents future input; it does not undo edits already made.

## It says “Paused for you”

The conversation/settings window is holding work at a safe action boundary. Select **Resume task**, say “resume task,” or close the review window. Add next queues a request; it does not automatically resume the current task.

## It reaches Google but does not finish the request

Search results are an intermediate step. General research workflows are still experimental, and a task can exceed controller limits or encounter unsupported controls. Try a smaller request or a literal destination. Ordinary Cua use does not require enabling browser debugging.

## The API key is rejected

Confirm the engine and provider in Advanced/Setup. The default Cua controller needs an OpenRouter key. TypeSafe keys apply to the experimental Jev engine. A saved Keychain key overrides `.env`; replace the saved key if an old one remains. Provider account access and model availability can also affect requests.

## Models or runtime files are missing

For weights, use **Advanced → Local downloads → Verify / repair**. For runtime dependencies, run `python3 NotchPilot/setup.py` from the repository root. If the checkout was moved, rebuild so generated runtime paths point to the new location. Moving only the `.app` does not create a standalone installation.

## Reporting a bug

Include macOS version, Mac chip, selected engine, exact request, expected/actual behavior, and whether the result was visible in the target app. Copy the relevant message from **Conversation → Details**. Remove API keys, private document content, personal paths, and sensitive screen text before posting an issue. Never attach `.env`, Keychain contents, or the entire runtime cache.
