# Tamale conformance vectors — format v1

This directory is the language-neutral contract of the tamale kernel. Each
`*.json` file holds a family of scenarios:

```
{space₀, script, anchors} → {transport results}
```

Any implementation of the kernel (Elixir, Rust, TS, ...) is conformant when
it reproduces every scenario's expected results. The Elixir runner
(`test/conformance_test.exs`) is the reference implementation of this
format, not of the kernel.

## File shape

```json
{
  "format": 1,
  "scenarios": [ <scenario>, ... ]
}
```

## Scenario

| field | required | meaning |
|---|---|---|
| `name` | yes | unique within the file; `family/name` is the test id. zongzi-derived scenarios keep their golden-scenario id (e.g. `G-AN-01/...`) |
| `note` | no | free text; ignored by runners. Semantic flips vs zongzi are recorded here |
| `space` | no | genesis ids, in order; active at version 0. Default `[]` (digest/patch scenarios need no space) |
| `script` | no | list of **batches**; each batch is a list of ops applied atomically, bumping the version by 1 and producing one log entry |
| `truncate` | no | after the script, drop log entries at or below this version |
| `warps` | no | warp table for Metric transport (below) |
| `expect_space_error` | no | the first failing batch must fail with exactly this reason; earlier batches stay applied, later batches are not applied |
| `expect_version` | no | assert the final head version (catches non-atomic batches) |
| `cases` | no | list of `{anchor, expect}` transport checks run against the final space |
| `digest_cases` | no | list of `{base, expect}` canonical-digest checks (below) |
| `patch_cases` | no | list of `{base, payload, fresh_base, expect}` resolve checks (below) |

## Ids

ids are JSON strings or numbers. The reserved string `"head"` means the
front of the order where an op takes an `after_id`.

## Ops

```json
{"op": "insert", "id": 4, "after_id": 2}        "after_id": "head" = front
{"op": "delete", "id": 2}
{"op": "split",  "id": 2, "children": [2, 4]}   children[0] must equal id
{"op": "merge",  "ids": [2, 3], "into": 2}      into must equal ids[0]
{"op": "move",   "id": 3, "after_id": 1}
{"op": "retime", "id": 1, "old_span": [0, 10], "new_span": [0, 5]}
```

## Anchors

```json
{"type": "ordinal",  "refs": [1, 2], "adjacent": false, "at_version": 0}
{"type": "metric",   "coord": "seconds", "from": 1.0, "to": 3.0, "at_version": 0}
{"type": "relative", "ref": 2, "from_offset": -0.08, "to_offset": 0.05, "at_version": 0}
```

`adjacent` defaults to `false`, `at_version` to `0`. In expected results the
same defaults apply.

## Expected results

```json
{"status": "ok",        "anchor": <anchor>}
{"status": "clip",      "covered": [<metric anchor>, ...], "lost": [[from, to], ...]}
{"status": "undefined", "reason": <reason>}
{"status": "error",     "reason": <reason>}
{"status": "ambiguous", "candidates": [<anchor>, ...]}
```

Reasons are kernel terms in JSON clothing: an atom becomes a string, a tuple
becomes a list. `{:deleted, 2}` → `["deleted", 2]`, `:adjacency_broken` →
`"adjacency_broken"`.

`lost` intervals are in **old** coordinates; `covered` anchors are in **new**
coordinates. A `clip` result means the kernel survived partially — how much
loss voids the edit is the channel's policy, not the kernel's.

## Warps

Metric transport folds one warp per log entry, supplied by the caller. A
scenario provides them as a table keyed by coordinate system and entry
version:

```json
"warps": [
  {"coord": "seconds", "entry": 1,
   "segments": [{"old": [0, 20], "new": [0, 10]}]}
]
```

Entries not listed default to the identity warp. Segments are piecewise
linear, monotone, non-overlapping on both sides (validated by
`Warp.from_segments/1` semantics).

Warps attach to **log entries**, so an edit that moves no ids still needs a
batch to be transport-visible: a pure tempo change enters the log as
`retime` batches of the affected elements.

## Numbers

JSON has one number type; runners must compare numerically (`2` equals
`2.0`). Vector authors should still prefer binary-exact values (integers,
halves, quarters) so exact float implementations compare cleanly.

## Digest and patch cases

`digest_cases` pin the canonical digest itself (spec:
`docs/spec/canonical-digest.md`):

```json
{"base": {"ph_1": [6, 12]},
 "expect": {"status": "ok", "digest": "<lowercase hex, 64 chars>"}}
{"base": {"onset": 1.5},
 "expect": {"status": "error", "reason": ["non_canonical", 1.5]}}
```

`patch_cases` pin the two resolve verdicts. The runner mounts a patch
from `base` + `payload`, then resolves it against `fresh_base`:

```json
{"base": {"ph_1": [6, 12]}, "payload": [1], "fresh_base": {"ph_1": [6, 13]},
 "expect": {"status": "conflict", "reason": "base_changed"}}
```

`{"status": "ok", "payload": ...}` is the other verdict. A
non-canonical `fresh_base` is an `error`, never a silent conflict.

## Deliberately out of scope

- **`Anchor.project/3`** (Relative → Metric) needs caller-supplied element
  spans, which are outside the kernel; vectors cover Relative transport
  only.
- **Policy**: split-ownership choice beyond the first-child convention,
  clip-vs-conflict thresholds, relocation after `undefined`. The kernel
  surfaces; policy decides.
