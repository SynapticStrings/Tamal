# Tamale

zongzi isn't 🫔 — this one is.

A minimal kernel for preserving **user edits across upstream regeneration
cycles**. What the user writes is a patch relative to an upstream base;
the base regenerates; after each regeneration every patch must be judged
*still applicable / applicable after transform / dead*. That is a
three-way merge with an explicit merge-base — the same problem `git
patch + base + transform rules` solves — and this kernel is its smallest
honest answer.

Tamale is a greenfield successor designed from a review of
[zongzi](https://github.com/SynapticStrings/Zongzi): it keeps zongzi's two-phase survival doctrine and
compresses its Anchor + Intervention + Timeline subsystems into a single
transport mechanism.

## Layering

```
kernel   : Space(id, order, version) · Op · Anchor/Transport · Patch     ← this package
policy   : relocation choice, clip-vs-conflict, digest chunk granularity ← callbacks
adapters : Tempo→Warp · curve samplers · windowing · score theory · engine bindings
```

The kernel holds no domain data, no music theory, no engine contract.

## The four kernel concepts

- **`Tamale.Space`** — a versioned identity space. ids are stable and
  never reused; every write is an op batch that bumps `version` and
  appends to an append-only log. The log *is* the tombstone record;
  `truncate/2` below the oldest live anchor version replaces GC.
- **`Tamale.Op`** — edit intent as a first-class script:
  `Insert / Delete / Split / Merge / Move / Retime`. Nothing is
  re-inferred from state diffs. (`diff(old, new)` exists only as a
  fallback adapter for edits that arrive as raw states.)
- **`Tamale.Anchor` + `Tamale.Transport`** — rebase is transport along
  the log: `{:ok, anchor'} | {:clip, covered, lost} |
  {:ambiguous, candidates} | {:undefined, reason}`. Anchor shapes:
  `Ordinal` (identity, with an `adjacent?` predicate for boundary
  anchors), `Metric` (coordinate intervals, transported by
  `Tamale.Warp`), `Relative` (identity + offset interval). Coordinates
  are exact rationals (`Tamale.Coord`; `docs/decisions/0007`) — integers
  promote, floats are rejected everywhere, same doctrine as the digest.
- **`Tamale.Patch`** — semantic survival: `(base_digest, payload)`.
  Digest match → apply; mismatch → conflict. No tolerance, ever.
  Digests are canonical and portable (`Tamale.Digest`; spec:
  `docs/spec/canonical-digest.md`) — floats are rejected at the digest
  boundary, because normalizing domain values into canonical form is
  the channel adapter's job (`docs/decisions/0005`).

## Invariants

- Edit intent is first-class; heuristics live only in the `diff` fallback.
- Structural survival (transport, at edit time) and semantic survival
  (`Patch.resolve`, at render time) are separate phases.
- No tolerance knobs; conflicts surface explicitly.
- Single writer: one linear log. (Offline/collaboration would
  reintroduce tombstones — as a deliberate extension, not a heuristic.)
- Kernel conventions, not policy: a split's first child inherits the
  parent id; a merge's `into` is `hd(ids)`; ids are never reused.

## Status: scaffold

Working and tested:

- `Space` op application with validation, versioning, log, truncation
- `Transport` for all three anchor shapes:
  - `Ordinal` (delete/split/merge/move/retime, conjunctive refs,
    head-state adjacency, `boundary_merged` when a merge collapses an
    `adjacent?` anchor's refs, truncated/future versions)
  - `Metric` (warp-fold transport; warps come from a Caller provider —
    the kernel holds no spans; partial survival surfaces as first-class
    `{:clip, covered, lost}`; the folded warp is available via
    `Transport.fold_warp/4` for `ChannelAdapter.warp_payload/2`)
  - `Relative` (Ordinal-rule host transport; absolute interval derived
    via `Anchor.project/3`; offsets may be negative and overhang the
    host)
- `Warp` algebra over exact rational coordinates (`Tamale.Coord`):
  `from_segments/1` (monotonicity-validated assembly), `compose/2`,
  `invert/1`, `map_interval/2` — a 1/3 tempo produces thirds, never
  float dust
- `Patch` digest resolve over canonical digests (`Tamale.Digest` —
  floats/structs/tuples rejected; atom keys encoded by name; spec +
  worked examples in `docs/spec/canonical-digest.md`)
- `ChannelAdapter.warp_payload/2` — the single channel-adapter callback
- JSON conformance vectors (`test/conformance/`, format v1): 40 scenarios
  across space/ordinal/metric/relative/digest/resolve, seeded from
  zongzi's `GOLDEN_SCENARIOS.md` including the deliberate semantic flips
  (G-AN-02 merge, G-INT-05 seconds anchor). Coordinates travel as
  integers or `"num/den"` strings; the metric family pins exact rational
  arithmetic (thirds, composed fractional scales). The Elixir
  implementation is now the reference runner; other languages implement
  against the vectors.

Guides and specs:

- `docs/zh/guide/caller-guide-zh.md` — the Caller orchestration contract
  (also the equinox migration manual): trio layout, edit-loop op
  conventions, two-phase survival, warp/digest obligations, engine
  protocol requirements, self-check list
- `docs/spec/canonical-digest.md` — portable digest spec v1

Not yet (roughly in order):

1. Warp-provider reference example (tempo map / span tables → segments;
   adapter layer, mapping open for discussion)
2. `diff(old, new)` fallback adapter — the one sanctioned home for
   heuristics, for edits that arrive as raw states (import, reload,
   collaboration)
3. Chunked digest helper — the pattern is settled
   (`docs/decisions/0006`); an optional policy-layer helper module may
   follow the first real channel

Design decisions: `docs/decisions/`.

## License

MIT (same as zongzi).
