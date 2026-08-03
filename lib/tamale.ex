defmodule Tamale do
  @moduledoc """
  zongzi isn't 🫔 — this one is.

  A minimal kernel for preserving user edits across upstream regeneration
  cycles: what the user writes is a **patch relative to an upstream base**;
  the base regenerates; after each regeneration every patch must be judged
  *still applicable / applicable after transform / dead*.

  That is a three-way merge with an explicit merge-base, and the kernel
  reduces it to four concepts:

  - `Tamale.Space` — versioned identity space (ids, order, op log). No
    domain data.
  - `Tamale.Op` — edit intent as a first-class, append-only script.
  - `Tamale.Anchor` + `Tamale.Transport` — anchors are expressions over
    the space; rebase is transport along the log.
  - `Tamale.Patch` — semantic survival: `(base_digest, payload)`.

  Everything else — relocation policy, warp construction, curve sampling,
  windowing, music theory, engine bindings — lives in policy callbacks or
  replaceable adapter packages, never in the kernel.
  """

  @typedoc "Element identity. Stable, never reused within a `Tamale.Space`."
  @type id :: term()

  @typedoc "Element identity for something."
  @type id(_t) :: id()

  @typedoc "Space version; increments by one per applied op batch."
  @type version :: non_neg_integer()
end
