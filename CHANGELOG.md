# Changelog

All notable changes are documented here. While 0.x, breaking changes may
land in any minor bump — they are always listed under **Breaking
Changes**, and any semantic change ships with new or updated conformance
vectors (a silent semantic flip is a test failure by construction).

## 0.1.0 — unreleased

The initial kernel line: four concepts, exact rational coordinates,
canonical digests, JSON conformance vectors.

### Breaking Changes

- **`Warp.at/2` and `Warp.map_interval/3` return error tuples** instead
  of raising on invalid coordinates or inverted intervals
  (`{:error, {:invalid_coordinate, value}}` /
  `{:error, :invalid_interval}`); the raising variants are `Warp.at!/2`
  and `Warp.map_interval!/3`. (`fd74d5c`)

### Added

- **`Tamale.Space`** — versioned identity space: stable never-reused ids,
  atomic op batches (`{:error, reason}` tuples throughout), an append-only
  log that doubles as the tombstone record, `truncate/2` as log-age GC.
  (`c1c72ee`)
- **`Tamale.Op`** — edit intent as a first-class script:
  `Insert / Delete / Split / Merge / Move / Retime`, with kernel identity
  conventions (a split's first child inherits the parent id; a merge's
  `into` is `hd(ids)`). (`c1c72ee`)
- **`Tamale.Anchor` + `Tamale.Transport`** — rebase as transport along
  the log: `{:ok, anchor'} | {:clip, covered, lost} |
  {:ambiguous, candidates} | {:undefined, reason}`. Shapes: `Ordinal`
  (conjunctive refs, head-state adjacency), `Metric` (warp-fold
  transport, first-class clip), `Relative` (Ordinal-rule host transport +
  `Anchor.project/3`). (`c1c72ee`, `52b6fa3`)
- **`Tamale.Warp`** — monotone partial maps: `from_segments/1`
  (monotonicity-validated assembly), `compose/2`, `invert/1`,
  `map_interval/2`. (`c1c72ee`)
- **`Tamale.Coord`** — exact rational coordinates `{num, den}`: integers
  promote, floats are rejected at every kernel entry point (Metric /
  Relative anchors, `Retime` spans, warp segments, `Anchor.project/3`).
  Wire form: JSON integer when `den == 1`, `"num/den"` string otherwise.
  (`644d849`)
- **`Tamale.Patch` + `Tamale.Digest`** — semantic survival via canonical
  digests (spec v1: `docs/spec/canonical-digest.md`); floats, tuples and
  structs rejected at the digest boundary. (`12ecbf2`)
- **`Tamale.ChannelAdapter`** — the single kernel-mandated channel
  callback, `warp_payload/2`. (`c1c72ee`)
- **`Transport.fold_warp/4`** — the warp `transport/3` folds internally
  is now public (and transport delegates to it), so
  `ChannelAdapter.warp_payload/2` receives exactly the folded warp.
  (`fd74d5c`)
- **`boundary_merged`** — an `adjacent?` anchor whose refs are collapsed
  by a `Merge` dies with `{:undefined, :boundary_merged}` (the boundary
  it names is gone); plain conjunctive refs still deduplicate onto
  `into` (G-AN-02). Pinned by the new G-AN-03 vectors. `Merge` also
  rejects duplicate ids with `:merge_duplicate_ids`. (`fd74d5c`)
- **JSON conformance vectors (format v1)** — 36 scenarios across
  space/ordinal/metric/relative/digest/resolve, seeded from zongzi's
  golden scenarios including the deliberate semantic flips (G-AN-02,
  G-INT-05), plus exact-rational pins (`fractional_rates_are_exact`,
  `fractional_compose_is_exact`) and boundary-merge semantics (G-AN-03).
  Format spec:
  `test/conformance/README.md`. (`52b6fa3`, `644d849`, `fd74d5c`)
- **Docs** — decision records `docs/decisions/0001`–`0007`; Chinese
  caller guide (`docs/zh/guide/caller-guide-zh.md`): the Caller
  orchestration contract. (`12ecbf2`, `644d849`)

### Fixed

- **`Warp.map_interval/3` at jump boundaries** — an interval (or clip
  fragment) starting exactly at an insertion jump now takes its start
  image from the arriving piece; previously the departing piece's value
  leaked in through first-piece boundary resolution, producing images
  with no preimage in the anchor's support. Pinned by the new
  `interval_starting_at_jump_uses_arriving_piece` and
  `clip_fragment_starting_at_jump_uses_arriving_piece` vectors.
- **Transport rejects refs born after `at_version`** — an `Insert` (or a
  ref-creating `Split`) inside the folded log is
  `{:error, {:unknown_ref, id}}`, like a dangling head ref
  (docs/decisions/0002). Pinned by the new
  `ref_born_after_at_version_is_error` and
  `split_child_born_after_at_version_is_error` vectors.
- **`Tamale.Digest` rejects invalid UTF-8** — byte strings and map keys
  that are not valid UTF-8 are rejected (`{:non_canonical, value}` /
  `{:non_canonical_key, key}`); spec v1 updated, including the
  `non_canonical_key` reason and a map-encoding typo.
- **`Anchor.project/3` rejects inverted offset intervals** —
  `from_offset > to_offset` is `{:error, :invalid_interval}`; overhanging
  the host stays legal.
- **Docs** — `Warp.compose/2` now documents that measure-zero
  (single-point) intersections are dropped.
