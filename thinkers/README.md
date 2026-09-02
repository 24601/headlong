# thinkers/

The thought processes that make up a mind. Each subdirectory is one
thinker: a `step` executable that produces the next thought, and a
`subscriptions.jsonl` that says which trajectory entries wake it. The
`thinkers` dispatcher in [bin/](../bin/) runs them.

- `monolith/` is the main mind loop, with its prompt in `prompt.md`.
- `responder/` handles fast chat replies.
- `retrieval/` is passive memory recall (memories that share words with
  the current step surface as observations). Ships disabled: delete its
  `disabled` marker in an identity's `thinkers/retrieval/` to turn it on.
- `gbrain-recall/` is optional, remote GBrain page recall. It ships disabled
  and makes no Headlong LLM call. It sends bounded message/thought queries to
  `gbrain call --stdin recall`, accepts only protocol v1, ignores the facts
  arm, and appends bounded world-visible page hits as quoted **untrusted
  evidence**. That evidence cannot authorize tool use, chat, writes, or other
  actions. The global template's `disabled` marker must remain in place.
- `_lib/` holds shell helpers shared by the thinkers.

## Enabling GBrain recall

Prerequisites: `jq`, `gbrain`, and GNU `timeout` (or `gtimeout`) must be on the
thinker service's `PATH`; the GBrain CLI must already be configured for the
remote API. The remote recall boundary must enforce `visibility=world` for all
returned material. Do not enable this thinker against a trusted-local/private
GBrain read path. Query text is sent only as JSON on stdin, never in argv.

First reconcile the bundled thinker into the identity, then opt in with the
per-identity `enabled` marker. This works for both copy and symlink installs and
leaves the global disabled marker untouched:

```bash
identity sync-thinkers <identity>
identity_path=$(identity info --path <identity>)
touch "$identity_path/thinkers/gbrain-recall/enabled"
thinkers start gbrain-recall
```

To roll back, stop it and remove only the per-identity opt-in:

```bash
thinkers stop gbrain-recall
rm -f "$identity_path/thinkers/gbrain-recall/enabled"
```

Defaults are six results, a 1,200-character query, a 20-second child timeout,
a five-minute cooldown between **successful thought recalls only**, and durable
retry beginning at 15 seconds with a 15-minute cap. Message recalls neither
consume nor wait for the thought cooldown. Failed calls retain only step
id/type/attempt/timing and rehydrate query text from the root trajectory on a
dispatcher wake; no query or retrieved text is persisted in retry state.

Privacy model: obvious credential-like query content is rejected locally;
outgoing, cross-identity, self-source, blank, and malformed triggers are also
ignored. This is defense in depth, not a general sensitive-data classifier.
Only enable it when inbound message/thought text is permitted to cross the
remote world-only boundary. Results are field- and output-bounded, control
characters are neutralized, and facts are never copied into the trajectory.
Configuration bounds are enforced for `GBRAIN_RECALL_LIMIT` (1–20),
`GBRAIN_RECALL_QUERY_CHARS` (32–4,000), `GBRAIN_RECALL_TIMEOUT` (1–120s),
`GBRAIN_RECALL_THOUGHT_COOLDOWN` (0–86,400s), retry base (1–3,600s), retry cap
(1–86,400s, not below base), and retry max exponent (0–16). Invalid settings
fail closed with one operator signal.

Code here counts against the under-10K-lines core (`cloc bin/ thinkers/`).
