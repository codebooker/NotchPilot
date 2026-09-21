# Contributing

Start with a reproducible issue or a focused pull request. NotchPilot is still a local prototype; improvements to dependable basic interactions matter more than broader claims about what it can do.

## Set up

Follow [the README](README.md#get-it-running), then read [Architecture](docs/architecture.md) and [Testing](docs/testing.md). Work on a branch and keep changes small enough to exercise in a disposable workflow.

## Preserve the session contract

- Opening voice makes the microphone ready without a click.
- Stop must invalidate pending callbacks and prevent later input.
- A recoverable action failure preserves listening while clearing dependent work.
- The compact strip must not steal keyboard focus.
- Exact app/window/field checks stay in place before input.
- Do not add an all-key global event monitor; it previously caused duplicate typing.
- Do not add a silent provider fallback or send local interpretation to an online service.
- Keep credentials, model weights, runtime caches, recordings, and private traces out of Git.

Run appropriate Python and native checks, and test affected UI behavior on a real Mac. Describe what was actually observed. Include known failures instead of treating a model’s completion message as proof.

## Pull requests

Explain the user-visible problem, resulting behavior, and validation. For interface changes, include a sanitized screenshot or native render in both relevant appearances. For input/control changes, cover cancellation, focus changes, and partial/refused actions.

Contributions are made under the repository’s existing [AGPL v3 license](LICENSE). Preserve notices and licenses for any third-party code or assets you include.
