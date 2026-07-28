# Canonical digest — spec v1

The `Tamale.Patch` survival check is `digest(new_base) == base_digest`.
For that check to mean the same thing in every language — and for Patch
to join the conformance vectors — the digest is specified here, not left
as an implementation detail.

    digest(term) = lowercase_hex( sha256( canonical_encoding(term) ) )

The Elixir reference implementation is `Tamale.Digest`.

## Canonical terms

The kernel digests only this subset — a JSON-shaped data model:

```
canonical := nil | true | false
           | integer                      (arbitrary precision)
           | string                       (UTF-8)
           | [canonical, ...]
           | { string_key: canonical, ... }
```

Anything else is **rejected** with `{:error, {:non_canonical, value}}`:
floats, tuples, structs/classes, map keys that are not strings. This is
deliberate. Adapting domain values into canonical form is the channel
adapter's obligation (`docs/decisions/0005`), and rejection is how the
kernel keeps it honest — a float that slips through would make the
digest depend on a language's float printing, which is exactly what this
spec exists to prevent.

Elixir convenience: map keys may be atoms; they encode as their name
(`:onset` → `"onset"`). A collision after conversion (`%{a: 1, "a" => 2}`)
is `{:error, :duplicate_keys}`. Other languages use string keys only.

## Canonical encoding

UTF-8 bytes, no whitespace anywhere:

- `nil` → `null`; `true` → `true`; `false` → `false`
- integer → decimal literal, `-` prefix for negatives, no leading zeros
- string → `"` + escaped + `"`, where escaping replaces `"` with `\"`,
  `\` with `\\`, and every C0 control byte (< 0x20) with `\uXXXX`
  (four lowercase hex digits). **All other bytes pass through as raw
  UTF-8** — no `\n` shortcuts, no `\u` escapes for non-ASCII
- list → `[` + elements joined by `,` + `]`
- map → `{` + pairs joined by `,` + `]`, each pair
  `"` + escaped_key + `":"` + value. Pairs are **sorted by the raw
  UTF-8 bytes of the unescaped key** (byte-wise comparison, which for
  UTF-8 equals codepoint order)

Empty list `[]`, empty map `{}`. No trailing commas, no spaces.

## Floats: the adapter contract

Floats never enter the digest. The channel adapter normalizes them
first, choosing a declared resolution (`docs/decisions/0005`):

- **Decimal strings** — e.g. seconds rounded with exact decimal
  arithmetic (`Decimal` in Elixir): `"0.1250"`. The string *is* the
  canonical form; the kernel hashes it like any other string.
- **Frame indices** — channels that are natively frame-based
  (DiffSinger phoneme timing) convert to integers (`round(sec * fps)`)
  and get canonical integers for free.

Because normalization is a deterministic function with a declared
resolution, any change at that resolution still conflicts — nothing is
silently absorbed. That is the line between normalization (legal) and a
similarity threshold (a tolerance backdoor, illegal).

## Worked examples

```
{"a":[1,"x"],"b":null}
  → 854ef06dc57f5dfed10206344ab2d02e0b6c84b0e19436703a5afd0f1f9f2687

{"ph_1":["0.1250","0.2500"],"ph_2":["0.3750","0.1250"]}
  → 6451cb39345cfeef323041aa247be772c4774f00e5c22341c97370ed7a365a0a

{"ph_1":[6,12],"ph_2":[18,6]}
  → d6122a8fce03ca7a7bb7520ee2624fbedf30800c20851bcb84ccf469d286fe82
```

The same examples are executable conformance vectors in
`test/conformance/patch.json`.

## Conformance

A conformant implementation passes `test/conformance/patch.json`:

- `digest/*` scenarios pin the encoding (via expected digests) and the
  rejection of floats
- `resolve/*` scenarios pin the two verdicts — `{:ok, payload}` /
  `{:conflict, :base_changed}` — plus the rule that a non-canonical
  *fresh* base is an error, never a silent conflict

Digest values are compared as lowercase hex strings, 64 chars.
