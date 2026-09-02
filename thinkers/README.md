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
- `gbrain-curator/` incrementally sends selected trajectory records to the
  identity owner's configured GBrain. It makes no Headlong LLM call and ships
  disabled. Configure GBrain and the optional `GBRAIN_CURATOR_*` limits, decide
  whether to set `GBRAIN_CURATOR_BACKFILL=1`, then delete only that identity's
  `thinkers/gbrain-curator/disabled` marker. To disable it again, recreate any
  regular file at that path. This marker is identity-local in both copy and
  `--symlinks` installs; syncing thinkers preserves an operator's removal and
  never removes the bundled template marker.
  By default it excludes observations and runtime machinery. Historical
  timestamps remain labeled in backfill text, but the batched `extract_facts`
  interface has no truthful per-fact `valid_from`, so it does not invent a
  single batch timestamp as provenance.
- `_lib/` holds shell helpers shared by the thinkers.

Code here counts against the under-10K-lines core (`cloc bin/ thinkers/`).
