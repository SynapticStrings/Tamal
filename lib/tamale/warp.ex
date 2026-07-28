defmodule Tamale.Warp do
  @moduledoc """
  A monotone partial map between coordinate systems — the transport medium
  for `Tamale.Anchor.Metric`.

  A warp answers one question: *where did coordinate `x` go?* — `{:ok, x'}`
  or `:undefined` when `x` lies in a deleted region. Tempo changes, note
  drags, duration edits and ripple deletes all reduce to the same thing: a
  warp.

  ## Representation

  Either `:identity` or a sorted list of linear pieces
  `{old_start, old_stop, new_start, new_stop}`. Pieces are closed
  intervals; where abutting pieces share an endpoint, `at/2` resolves the
  (measure-zero) ambiguity to the first piece. Old domains and new images
  are each non-overlapping and monotone — a warp is **piecewise monotone
  by definition**; non-monotone reordering is `Tamale.Op.Move`, not a
  warp, and `from_segments/1` rejects it.

  ## Algebra

  - `from_segments/1` — piecewise assembly from `{old_span, new_span}`
    segment pairs (the only raw material is coordinate data; turning tempo
    maps or element span tables into segments is the adapter layer's job)
  - `compose/2` — partial composition, domain intersects
  - `invert/1` — new coordinates become the domain
  - `map_interval/2` — interval transport with first-class partial
    coverage (`{:clip, covered, lost}`)
  """

  @typedoc "`{old_start, old_stop, new_start, new_stop}` — linear, strictly monotone."
  @type piece :: {number(), number(), number(), number()}

  @typedoc "A `{from, to}` interval."
  @type interval :: {number(), number()}

  @type t :: %__MODULE__{pieces: :identity | [piece()]}

  defstruct pieces: :identity

  @doc "The identity warp: every coordinate maps to itself."
  @spec identity() :: t()
  def identity, do: %__MODULE__{}

  @doc "A single-piece warp linearly mapping `old_span` onto `new_span`."
  @spec from_span(interval(), interval()) :: t()
  def from_span({o0, o1}, {n0, n1}) when o0 < o1 and n0 < n1 do
    %__MODULE__{pieces: [{o0, o1, n0, n1}]}
  end

  @doc """
  Assembles a piecewise warp from `{old_span, new_span}` segments.

  Segments are normalized (sorted by old start). Both the old domains and
  the new images must be non-overlapping and monotone; shared endpoints
  are allowed. Errors: `:invalid_segment` (malformed or non-increasing
  spans), `:segments_overlap`, `:non_monotone`.
  """
  @spec from_segments([{interval(), interval()}]) :: {:ok, t()} | {:error, term()}
  def from_segments(segments) when is_list(segments) do
    if Enum.all?(segments, &valid_segment?/1) do
      pieces =
        segments
        |> Enum.map(fn {{o0, o1}, {n0, n1}} -> {o0, o1, n0, n1} end)
        |> Enum.sort()

      case check_layout(pieces) do
        :ok -> {:ok, %__MODULE__{pieces: pieces}}
        {:error, _} = err -> err
      end
    else
      {:error, :invalid_segment}
    end
  end

  @doc "Where did coordinate `x` go? `:undefined` outside all pieces."
  @spec at(t(), number()) :: {:ok, number()} | :undefined
  def at(%__MODULE__{pieces: :identity}, x), do: {:ok, x}

  def at(%__MODULE__{pieces: pieces}, x) do
    case eval(pieces, x) do
      nil -> :undefined
      y -> {:ok, y}
    end
  end

  @doc """
  Composes two warps: `compose(outer, inner)` maps `x` through `inner`
  first, then `outer` — the partial composition, defined exactly where
  `inner(x)` is defined and lands in `outer`'s domain.
  """
  @spec compose(t(), t()) :: t()
  def compose(%__MODULE__{pieces: :identity}, inner), do: inner
  def compose(outer, %__MODULE__{pieces: :identity}), do: outer

  def compose(%__MODULE__{pieces: outer}, %__MODULE__{pieces: inner}) do
    pieces =
      for {o0, o1, n0, n1} <- inner,
          {p0, p1, q0, q1} <- outer,
          lo = max(n0, p0),
          hi = min(n1, p1),
          lo < hi do
        x_lo = o0 + (lo - n0) * (o1 - o0) / (n1 - n0)
        x_hi = o0 + (hi - n0) * (o1 - o0) / (n1 - n0)
        y_lo = q0 + (lo - p0) * (q1 - q0) / (p1 - p0)
        y_hi = q0 + (hi - p0) * (q1 - q0) / (p1 - p0)
        {x_lo, x_hi, y_lo, y_hi}
      end

    %__MODULE__{pieces: Enum.sort(pieces)}
  end

  @doc """
  Inverts a warp: new coordinates become the domain. The inverse is
  partial in both directions — coordinates outside the original images
  become undefined.
  """
  @spec invert(t()) :: t()
  def invert(%__MODULE__{pieces: :identity}), do: identity()

  def invert(%__MODULE__{pieces: pieces}) do
    %__MODULE__{
      pieces: pieces |> Enum.map(fn {o0, o1, n0, n1} -> {n0, n1, o0, o1} end) |> Enum.sort()
    }
  end

  @doc """
  Maps the interval `[from, to]` through the warp.

  - fully covered  → `{:ok, {from', to'}}` — including intervals stretched
    over an insertion (a jump in the warp): the anchor grows to enclose
    the new material; what happens to the payload is the adapter's call
    (`Tamale.ChannelAdapter.warp_payload/2`)
  - partly covered → `{:clip, covered, lost}` where `covered` are the
    image intervals (new coordinates, ordered) and `lost` the
    sub-intervals of `[from, to]` (old coordinates) with no image
  - no coverage    → `:undefined`

  For a non-point interval, coverage of measure zero (a shared boundary
  endpoint) does not count as coverage.
  """
  @spec map_interval(t(), number(), number()) ::
          {:ok, interval()} | {:clip, [interval()], [interval()]} | :undefined
  def map_interval(%__MODULE__{pieces: :identity}, from, to) when from <= to do
    {:ok, {from, to}}
  end

  def map_interval(%__MODULE__{pieces: pieces}, from, to) when from <= to do
    covered_old =
      for {o0, o1, _n0, _n1} <- pieces,
          lo = max(o0, from),
          hi = min(o1, to),
          lo <= hi,
          from == to or lo < hi do
        {lo, hi}
      end

    case covered_old do
      [] ->
        :undefined

      frags ->
        case gaps(frags, from, to) do
          [] ->
            {:ok, {eval(pieces, from), eval(pieces, to)}}

          lost ->
            covered_new = Enum.map(frags, fn {f, t} -> {eval(pieces, f), eval(pieces, t)} end)
            {:clip, covered_new, lost}
        end
    end
  end

  # ---- helpers ----

  defp valid_segment?({{o0, o1}, {n0, n1}}) do
    is_number(o0) and is_number(o1) and is_number(n0) and is_number(n1) and o0 < o1 and n0 < n1
  end

  defp valid_segment?(_), do: false

  defp check_layout(pieces) do
    pieces
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [{_o0, o1, _n0, n1}, {p0, _p1, q0, _q1}], :ok ->
      cond do
        p0 < o1 -> {:halt, {:error, :segments_overlap}}
        q0 < n1 -> {:halt, {:error, :non_monotone}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp eval(pieces, x) do
    with {o0, o1, n0, n1} <- Enum.find(pieces, fn {o0, o1, _, _} -> x >= o0 and x <= o1 end) do
      n0 + (x - o0) * (n1 - n0) / (o1 - o0)
    end
  end

  # Sub-intervals of `[from, to]` not covered by the sorted fragment list.
  defp gaps(frags, from, to) do
    {gaps, cursor} =
      Enum.map_reduce(frags, from, fn {f, t}, cursor ->
        {if(f > cursor, do: [{cursor, f}], else: []), max(cursor, t)}
      end)

    Enum.concat(gaps) ++ if(cursor < to, do: [{cursor, to}], else: [])
  end
end
