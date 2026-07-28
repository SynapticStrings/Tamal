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
  `Tamale.Warp`), `Relative` (identity + offset interval).
- **`Tamale.Patch`** — semantic survival: `(base_digest, payload)`.
  Digest match → apply; mismatch → conflict. No tolerance, ever.

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
    head-state adjacency, truncated/future versions)
  - `Metric` (warp-fold transport; warps come from a Caller provider —
    the kernel holds no spans; partial survival surfaces as first-class
    `{:clip, covered, lost}`)
  - `Relative` (Ordinal-rule host transport; absolute interval derived
    via `Anchor.project/3`; offsets may be negative and overhang the
    host)
- `Warp` algebra: `from_segments/1` (monotonicity-validated assembly),
  `compose/2`, `invert/1`, `map_interval/2`
- `Patch` digest resolve
- `ChannelAdapter.warp_payload/2` — the single channel-adapter callback

Not yet (roughly in order):

1. Chunked base digests (conflict localization) at the policy layer
2. JSON conformance vectors — `{space₀, script, anchors} → {survived,
   conflicts, transported anchors}` — seeded from zongzi's
   `GOLDEN_SCENARIOS.md`; the Elixir implementation should degrade to
   reference implementation once the vectors exist

Design decisions: `docs/decisions/`.

## License

MIT (same as zongzi).
