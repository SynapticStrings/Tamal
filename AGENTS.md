# AGENTS.md — Tamale

## Essential Commands

```bash
mix test                      # run all tests (unit + conformance)
mix test test/tamale/space_test.exs  # run a single test file
mix format                    # auto-format (config: .formatter.exs)
mix compile --warnings-as-errors     # strict compile
mix precommit                 # compile + format + test (alias in mix.exs)
```

No dependencies (`deps/` is empty). Elixir ~> 1.18 required. Extra apps: `:crypto`, `:logger`.

## Architecture Overview

Tamale is a zero-dependency Elixir kernel for **preserving user edits across upstream regeneration cycles**. It solves three-way merge with an explicit merge-base. The kernel holds no domain data, no music theory, no engine contract — only identity, order, and edit intent.

### The Four Kernel Concepts

```
Space  ──→  Op  ──→  Anchor + Transport  ──→  Patch
(ids,       (edit     (structural            (semantic
 log,       intent)    survival at            survival at
 version)              edit time)             render time)
```

1. **`Tamale.Space`** — versioned identity space. ids are stable and never reused. Every write is an `Op` batch that bumps `version` by one and appends one log entry. The log IS the tombstone record; `truncate/2` replaces GC.

2. **`Tamale.Op`** — six op structs (`Insert`, `Delete`, `Split`, `Merge`, `Move`, `Retime`) defined as nested modules under `Tamale.Op`. Edit intent is first-class; nothing is re-inferred from state diffs.

3. **`Tamale.Anchor` + `Tamale.Transport`** — three anchor shapes (`Ordinal`, `Metric`, `Relative`). Transport is the entire rebase: fold the anchor along `log[at_version..head]`. Results: `{:ok, anchor'}` | `{:clip, covered, lost}` | `{:ambiguous, candidates}` | `{:undefined, reason}`.

4. **`Tamale.Patch`** — semantic survival: `(base_digest, payload)`. Digest match → apply; mismatch → conflict. No tolerance, ever.

### Supporting Modules

- **`Tamale.Coord`** — exact rational coordinates `{num, den}`. The kernel's only number type. Integers promote, floats are rejected everywhere.
- **`Tamale.Warp`** — monotone partial map between coordinate systems. Piecewise linear; endpoints are `Coord` rationals. Algebra: `from_segments/1`, `compose/2`, `invert/1`, `map_interval/2`.
- **`Tamale.Digest`** — canonical portable digest: `sha256(canonical_encoding(term))` as lowercase hex. Rejects floats, structs, tuples.
- **`Tamale.ChannelAdapter`** — a single callback: `warp_payload(payload, warp)`. The only kernel-mandated channel-adapter callback. Get the warp from `Transport.fold_warp/4` (same args as `transport/3`).

## The Float Rejection Doctrine (Critical Gotcha)

**Floats are rejected at every kernel boundary.** This is the single most important convention. If you pass a float where a coordinate or canonical term is expected, you get an error — never a silent conversion.

- `Coord.cast(0.5)` → `{:error, {:invalid_coordinate, 0.5}}`
- `Coord.cast!(0.5)` → raises `ArgumentError`
- `Digest.encode(1.5)` → `{:error, {:non_canonical, 1.5}}`
- `Warp.from_segments([{{0.0, 10}, {0, 10}}])` → `{:error, :invalid_segment}`
- `Space.apply_op(s, %Retime{old_span: {0.0, 10}, ...})` → `{:error, :invalid_span}`

**Why**: Normalizing domain floats into exact values (seconds → microseconds, decimal strings, frame indices) is the **channel adapter's job**, not the kernel's. Rejecting floats at the boundary keeps that adapter obligation honest.

**When writing tests**: Use integers or `{num, den}` pairs for all coordinates. Use a helper like `defp dyn(x), do: x` to pass floats to runtime-checked functions without dialyzer warnings (see `coord_test.exs:31`).

## Conformance Vectors

`test/conformance/*.json` contains 40 scenarios across five families: `space.json`, `ordinal.json`, `metric.json`, `relative.json`, `patch.json`. These are the **cross-language contract** — any implementation (Elixir, Rust, TS) is conformant when it reproduces every scenario's expected results.

The Elixir runner is `test/conformance_test.exs` (`Tamale.ConformanceRunner`). Vectors are loaded at compile time via `@external_resource` and generate one ExUnit test per scenario.

Adding a new scenario: edit the relevant JSON file, add an entry to the `"scenarios"` array. Format spec: `test/conformance/README.md`. Coordinates on the wire: JSON integer when `den == 1`, `"num/den"` string otherwise.

## Identity Conventions (Kernel-Level)

These are hard rules, not policy:

- **Split**: first child inherits the parent id — `children` must be `[parent_id | new_ids]`. `hd(children) != id` → `:split_identity` error.
- **Merge**: `into` must be `hd(ids)`. `into != hd(ids)` → `:merge_into` error. Merged ids must be unique (`:merge_duplicate_ids`) and adjacent in the current order.
- **Delete**: terminal for anchors referencing the id. Relocation is policy, not transport.
- **Retime**: carries `old_span` / `new_span` so warp construction has its inputs. Structure and identity are unaffected.
- **ids are never reused**: a deleted id stays dead in `Space.seen` (a `MapSet`). `{:error, {:id_reused, id}}` on attempt.
- **refs must be live at `at_version`**: an `Insert` (or a ref-creating `Split`) inside the folded log range means the anchor predates the ref — `{:error, {:unknown_ref, id}}`, same as a dangling head ref.

## Error Handling Pattern

The kernel uses `{:ok, value} | {:error, reason}` tuples throughout — never raises in normal operation. Raising variants (`new!`, `cast!`, `Warp.at!/2`, `Warp.map_interval!/3`) exist for tests and known-good inputs. Error reasons are atoms or tagged tuples:

```elixir
{:error, :duplicate_ids}
{:error, {:unknown_id, id}}
{:error, {:invalid_coordinate, value}}
{:error, {:non_canonical, value}}
{:error, :log_truncated}
{:error, {:future_version, v}}
```

## Testing Patterns

- All test modules use `use ExUnit.Case, async: true` (conformance tests use `async: false` because they share the compile-time scenario data).
- Test helper `test_helper.exs` is just `ExUnit.start()` — no special config.
- Tests assert on exact struct shapes: `assert {:ok, %Ordinal{refs: [:b], at_version: 1}} = Transport.transport(...)`.
- The `dyn/1` pattern for bypassing dialyzer on deliberately-invalid inputs: `defp dyn(x), do: x` (see `coord_test.exs:32`).
- Unit tests in `test/tamale/` cover each module individually; conformance tests in `test/conformance_test.exs` exercise cross-module integration.

## Module Structure

```
lib/
├── tamale.ex                  # top-level module: types id/version, moduledoc
└── tamale/
    ├── space.ex               # Space struct + apply_batch + log + truncate
    ├── op.ex                  # Op submodules: Insert, Delete, Split, Merge, Move, Retime
    ├── anchor.ex              # Anchor submodules: Ordinal, Metric, Relative + project/3
    ├── transport.ex           # transport/2,3 — the entire rebase logic
    ├── coord.ex               # exact rational arithmetic {num, den}
    ├── warp.ex                # piecewise monotone partial maps
    ├── patch.ex               # semantic survival via digest match
    ├── digest.ex              # canonical encoding + sha256
    └── channel_adapter.ex     # single callback behaviour
```

Nested modules: `Op` and `Anchor` each define their variants as `defmodule` blocks inside the parent. This is the project's convention — not a single flat module per file.

## Design Decisions

Key decisions are documented in `docs/decisions/` (in Chinese with English status tags):

| File | Decision |
|---|---|
| `0001` | Edit intent is first-class ops, not state diffs |
| `0002` | Identity conventions (split first-child, merge into=hd) |
| `0003` | Warp-based Metric transport; deliberate semantic flips vs zongzi |
| `0004` | Clip and relative semantics |
| `0005` | Digest = judge, sketch = forensic; normalization vs tolerance |
| `0006` | Chunked digests for localized conflict |
| `0007` | Exact rational coordinates; floats rejected everywhere |

## Docs and Specs

- `docs/spec/canonical-digest.md` — portable digest spec with worked examples
- `docs/zh/guide/caller-guide-zh.md` — Caller orchestration contract and migration manual
- `test/conformance/README.md` — conformance vector format spec

## Common Pitfalls

1. **Passing floats to anything Coord-related** — always use integers or `{num, den}` pairs.
2. **Forgetting `adjacent?` defaults to `false`** — in conformance vectors and in struct defaults.
3. **Merge adjacency check** — merged ids must be a contiguous run in the current `ids` list, checked by `adjacent_run?/2` using `chunk_every`.
4. **Log is a plain list** — `log` is appended at the end (O(n) per batch). Fine at current scale; production can swap in a queue without changing semantics.
5. **`at_version` in anchors** — defaults to 0 in both struct defaults and conformance vectors. Anchors at head version (no log entries to fold) return immediately with coordinates normalized.
6. **Metric transport requires a 3-arity `transport/3`** — calling `transport/2` with a `Metric` anchor returns `{:error, :warp_provider_required}`.
7. **Warp composition order** — `compose(outer, inner)` maps x through inner first, then outer.
8. **`adjacent?` anchors die when a merge collapses their refs** — `{:undefined, :boundary_merged}`; plain conjunctive refs deduplicate onto `into` and survive (vectors G-AN-02 vs G-AN-03).
