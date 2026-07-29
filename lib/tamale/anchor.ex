defmodule Tamale.Anchor do
  @moduledoc """
  The anchor algebra.

  An anchor is an expression over a `Tamale.Space`, stamped with the
  `at_version` it is valid at. `Tamale.Transport` carries it forward along
  the op log. Three native shapes:

  - `Ordinal` — references element identity (one id, or several
    conjunctively; `adjacent?` expresses boundary anchors like "A|B").
  - `Metric` — references a coordinate interval (ticks, seconds, frame
    index); transported by `Tamale.Warp`, not by identity.
  - `Relative` — identity first, then an offset interval from the
    element's span ("0–50 ms after the start of phoneme 3").

  The algebra is deliberately closed: new shapes mean a new kernel version
  covered by new conformance vectors, not a user callback.
  """

  alias Tamale.Anchor.{Metric, Relative}

  defmodule Ordinal do
    @moduledoc """
    Identity anchor.

    - `refs` — ids the anchor depends on, **conjunctively**: losing any of
      them kills the anchor. (Disjunctive fallback — "relocate to the
      nearest live element" — is policy, not transport.)
    - `adjacent?` — when true, `refs` must remain consecutive in the
      space's order; breaking adjacency is `{:undefined, :adjacency_broken}`.
      This is how "the boundary between A and B" is expressed — as a
      first-class predicate, not a neighbor-similarity heuristic. The
      boundary is part of the referent: a `Merge` that collapses the refs
      removes it, and the anchor dies with `{:undefined, :boundary_merged}`.
    - `at_version` — space version these refs are valid at.
    """
    defstruct refs: [], adjacent?: false, at_version: 0

    @type t :: %__MODULE__{
            refs: [Tamale.id(), ...],
            adjacent?: boolean(),
            at_version: Tamale.version()
          }
  end

  defmodule Metric do
    @moduledoc """
    Coordinate anchor: an interval in some coordinate system (`:tick`,
    `:seconds`, `{:frames, hz}`, ...).

    Survives iff there is a monotone partial map (a `Tamale.Warp`) from the
    old coordinates to the new ones covering the anchor's support.
    Transport folds the per-entry warps a Caller provider supplies — the
    kernel holds no element spans and no tempo map. Partial coverage is a
    first-class result: `{:clip, covered, lost}` — see
    `Tamale.Transport`. Semantics: `docs/decisions/0003-warp-semantics.md`.

    Endpoints are exact rational coordinates (`Tamale.Coord`): integers
    are promoted, floats are rejected at transport time.
    """
    defstruct coord: nil, from: 0, to: 0, at_version: 0

    @type t :: %__MODULE__{
            coord: term(),
            from: Tamale.Coord.input(),
            to: Tamale.Coord.input(),
            at_version: Tamale.version()
          }
  end

  defmodule Relative do
    @moduledoc """
    Compound anchor: `ref` travels by identity (Ordinal rules), then the
    absolute interval is re-derived from the element's current span at use
    time — `Tamale.Anchor.project/3`, with element spans supplied by the
    Caller.

    Offsets are absolute from the element's start, are **not** rescaled
    when the host stretches, and may be negative or overhang the host
    ("80 ms before phoneme 3 starts" — preutterance). There is no
    within-host invariant. Offsets are exact rational coordinates
    (`Tamale.Coord`): integers are promoted, floats are rejected at
    transport time.
    """
    defstruct ref: nil, from_offset: 0, to_offset: 0, at_version: 0

    @type t :: %__MODULE__{
            ref: Tamale.id(),
            from_offset: Tamale.Coord.input(),
            to_offset: Tamale.Coord.input(),
            at_version: Tamale.version()
          }
  end

  @type t :: Ordinal.t() | Metric.t() | Relative.t()

  @doc """
  Projects a `Relative` anchor to an absolute `Metric` interval, given the
  host element's current span from the Caller.

  Offsets may be negative and may overhang the host (preutterance); there
  is no within-host invariant. What an overhanging interval *means* for
  survival is judged later, by warp (`Tamale.Warp.map_interval/2` clip
  semantics), not here. Offsets and the span are cast to rational
  coordinates; floats are `{:error, {:invalid_coordinate, value}}`.
  """
  @spec project(
          Relative.t(),
          term(),
          (Tamale.id() -> {Tamale.Coord.input(), Tamale.Coord.input()} | nil)
        ) ::
          {:ok, Metric.t()} | {:error, {:unknown_id, Tamale.id()} | {:invalid_coordinate, term()}}
  def project(%Relative{} = anchor, coord, span_fun) when is_function(span_fun, 1) do
    with {:ok, from_offset} <- Tamale.Coord.cast(anchor.from_offset),
         {:ok, to_offset} <- Tamale.Coord.cast(anchor.to_offset),
         {start, _stop} <- span_fun.(anchor.ref),
         {:ok, start} <- Tamale.Coord.cast(start) do
      {:ok,
       %Metric{
         coord: coord,
         from: Tamale.Coord.add(start, from_offset),
         to: Tamale.Coord.add(start, to_offset),
         at_version: anchor.at_version
       }}
    else
      nil -> {:error, {:unknown_id, anchor.ref}}
      {:error, _} = err -> err
    end
  end
end
