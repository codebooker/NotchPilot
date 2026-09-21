# Cua S1 Forms: fast matching, limited judgment

**Decision:** keep S1 Forms as an experiment. It correctly matched all 23 empty-field examples in this test, but its confidence did not reliably distinguish mistakes. It is not wired into NotchPilot's default controller.

[Cua S1](https://github.com/trycua/cua/tree/main/libs/cua-s1) is a project for small specialists, rather than a general computer-use agent. The first [Forms checkpoint](https://huggingface.co/cua-ai/cua-s1-forms) scores supplied alternatives for an observed field: choose an entity value, check, click, or skip. This is a plausible local replacement for a narrow classification step, not for understanding an entire request, navigating an app, or proving that a task finished.

## Local evaluation · September 21, 2026

The experiment used 60 locally authored fictional form decisions, with no fine-tuning and no form submission. The cases are separate from the upstream evaluation; training-data overlap has not been audited. Each example supplied the same 12 fictional profile entities and a field/button description using upstream rendering functions.

| Cases | Correct |
|---|---:|
| Empty fields with available values | **23/23** |
| Already-filled fields, expected skip | **16/23** |
| No suitable supplied value | **6/7** |
| Navigation/other buttons, expected skip | **3/4** |
| Submit classifier example, no execution | **1/1** |
| Already-checked checkbox | **1/1** |
| Optional promotional consent, expected skip | **1/1** |
| **Total** | **51/60 (85%)** |

The model has **706,048 parameters**. On this development Mac, CPU inference plus collation took a **1.38 ms median** and **2.12 ms p95**, using four PyTorch threads after warm-up. Loading took **176 ms**. These timings exclude app observation, input delivery, and verification. Local execution incurs no API token charge, but still consumes device resources.

Seven of the nine wrong predictions had confidence at least 0.95. Examples: a Password field was assigned the supplied postal code; Delete account received “click”; several already-filled name/email fields were assigned the email value. A high-confidence threshold alone is inadequate.

The upstream package's **63 tests passed** after installing its optional PDF dependency and including the Cua Driver contract fixture. That validates its test suite in this environment, not general form-filling competence.

## Input delivery is a separate problem

A separate local eight-field HTML smoke test used fictional values chosen by the classifier, delivered through the available Codex browser automation tools. Six values were observed correctly; email and phone remained empty after set-value/fill attempts and a typing fallback. No form was submitted. This is an unresolved delivery limitation of that test path, not an additional S1 classification error. The page and scripts are included for reproduction.

This was **not** a test of an integrated NotchPilot S1 executor. The upstream S1 README also states that portable Cua Driver's contract does not expose `set_value`; S1 fill execution fails closed unless the connected runtime advertises compatible token-based mutation. Our macOS integration needs an explicit, tested delivery adapter before this can become a product feature.

## A sensible integration experiment

1. A general interpreter obtains the user's intended task and supplied values.
2. S1 proposes values only for supported, empty fields with observed labels.
3. Deterministic rules preserve filled fields and exclude passwords, consent changes, and button actions from this matching route.
4. A host adapter binds each proposal to a fresh field token, delivers it, and verifies the value.
5. Unsupported fields go back to the controller or user; submission remains a separate action.

Measure end-to-end completion and harmful/wrong edits, not just classifier milliseconds. Add forms with dynamic fields, duplicate labels, dropdowns, validation errors, existing values, and missing data. These results do not establish that S1 beats Jev or other local classifiers on general computer use; that would need the same task suite and delivery path.

## Reproduction

- Source revision: `9bbfa7dd3e27ca7f1861ede70aaca390174493f9` in `trycua/cua`.
- Checkpoint revision: `f54adbf447f4ca6ec259f529ee3f2e3e09f8cc71` in `cua-ai/cua-s1-forms`.
- Runtime: PyTorch 2.14.0, CPU, four threads; checkpoint loaded from safetensors plus JSON, not pickle.
- [Evaluation script](../NotchPilot/experiments/eval_cua_s1.py), [raw fictional results](../NotchPilot/experiments/results/cua-s1.json), [local HTML fixture](../NotchPilot/experiments/s1_fixture.html).

Install the `cua-s1` Python package from the pinned source checkout in a separate environment, download the pinned model/config, then run:

```sh
python NotchPilot/experiments/eval_cua_s1.py \
  --model /path/to/model.safetensors --output /tmp/cua-s1-results.json
```

The checkpoint card identifies this release as MIT. The source README discusses possible different terms for future artifacts; recheck the specific artifact's license before distributing different weights. No model weights or new S1 runtime dependency are bundled with NotchPilot.
