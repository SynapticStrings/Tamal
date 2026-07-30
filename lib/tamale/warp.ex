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
  `{old_start, old_stop, new_start, new_stop}`. Every endpoint is an exact
  rational coordinate (`Tamale.Coord`), so interpolation and composition
  never accumulate float dust — a 1/3 tempo produces thirds, and
  conformance vectors can pin them. Pieces are closed intervals; where
  abutting pieces share an endpoint, `at/2` resolves the (measure-zero)
  ambiguity to the first piece. Old domains and new images are each
  non-overlapping and monotone — a warp is **piecewise monotone by
  definition**; non-monotone reordering is `Tamale.Op.Move`, not a warp,
  and `from_segments/1` rejects it.

  ## Default behaviour

  The `default` field controls what happens to coordinates outside all
  pieces:
  - `:undefined` (default) — the coordinate is lost (hole / ripple delete)
  - `:identity` — the coordinate passes through unchanged (non-ripple tick
    space: only Retimed regions transform)

  Use `total/1` to switch a warp to identity-fill mode.

  ## Algebra

  - `from_segments/1` — piecewise assembly from `{old_span, new_span}`
    segment pairs (the only raw material is coordinate data; turning tempo
    maps or element span tables into segments is the adapter layer's job)
  - `from_span/2` — single-piece convenience
  - `total/1` — lift a partial warp to total (uncovered → identity)
  - `compose/2` — partial composition, domain intersects
  - `invert/1` — new coordinates become the domain
  - `map_interval/2` — interval transport with first-class partial
    coverage (`{:clip, covered, lost}`)
  """

  alias Tamale.Coord

  @typedoc "`{old_start, old_stop, new_start, new_stop}` — linear, strictly monotone."
  @type piece :: {Coord.t(), Coord.t(), Coord.t(), Coord.t()}

  @typedoc "A `{from, to}` interval."
  @type interval :: {Coord.t(), Coord.t()}

  @type t :: %__MODULE__{pieces: :identity | [piece()], default: :undefined | :identity}

  defstruct pieces: :identity, default: :undefined

  @doc "The identity warp: every coordinate maps to itself."
  @spec identity() :: t()
  def identity, do: %__MODULE__{default: :undefined}

  @doc """
  A single-piece warp linearly mapping `old_span` onto `new_span`.

  This is the literal form for hand-written warps: endpoints are cast with
  `Coord.cast!/1` and a non-increasing span raises `ArgumentError`. For
  data-driven assembly use `from_segments/1`, which returns errors.
  """
  @spec from_span({Coord.input(), Coord.input()}, {Coord.input(), Coord.input()}) :: t()
  def from_span({o0, o1} = _old_span, {n0, n1} = _new_span) do
    o0 = Coord.cast!(o0)
    o1 = Coord.cast!(o1)
    n0 = Coord.cast!(n0)
    n1 = Coord.cast!(n1)

    unless Coord.lt?(o0, o1) and Coord.lt?(n0, n1) do
      raise ArgumentError, "invalid warp span: \#{inspect({_old_span, _new_span})}"
    end

    %__MODULE__{pieces: [{o0, o1, n0, n1}]}
  end

  @doc """
  Assembles a piecewise warp from `{old_span, new_span}` segments.

  Segments are cast to rational coordinates and normalized (sorted by old
  start). Both the old domains and the new images must be non-overlapping
  and monotone; shared endpoints are allowed. Errors: `:invalid_segment`
  (malformed, non-increasing, or non-coordinate spans — floats included),
  `:segments_overlap`, `:non_monotone`.

  The result has `default: :undefined` — coordinates outside segments are
  lost. Use `total/1` to switch to identity-fill.
  """
  @spec from_segments([{{Coord.input(), Coord.input()}, {Coord.input(), Coord.input()}}]) ::
          {:ok, t()} | {:error, term()}
  def from_segments(segments) when is_list(segments) do
    with {:ok, segments} <- cast_segments(segments) do
      pieces =
        segments
        |> Enum.map(fn {{o0, o1}, {n0, n1}} -> {o0, o1, n0, n1} end)
        |> sort_pieces()

      case check_layout(pieces) do
        :ok -> {:ok, %__MODULE__{pieces: pieces}}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Returns a copy of `warp` where coordinates outside all pieces pass
  through as identity instead of dying.

      warp |> Warp.from_segments!(segs) |> Warp.total()

  This is the typical need for non-ripple tick-space adapters: only the
  Retimed regions should transform; everything else stays put.
  """
  @spec total(t()) :: t()
  def total(%__MODULE__{} = warp), do: %{warp | default: :identity}

  @doc """
  Where did coordinate `x` go? `:undefined` outside all pieces.

  `x` is cast to a rational coordinate: floats are
  `{:error, {:invalid_coordinate, value}}`. The result is always a
  normalized rational. `at!/2` is the raising variant.
  """
  @spec at(t(), Coord.input()) ::
          {:ok, Coord.t()} | :undefined | {:error, {:invalid_coordinate, term()}}
  def at(warp, x) do
    with {:ok, x} <- Coord.cast(x) do
      do_at(warp, x)
    end
  end

  @doc "Raising variant of `at/2`, for tests and known-good inputs."
  @spec at!(t(), Coord.input()) :: {:ok, Coord.t()} | :undefined
  def at!(warp, x), do: do_at(warp, Coord.cast!(x))

  defp do_at(%__MODULE__{pieces: :identity}, x), do: {:ok, x}

  defp do_at(%__MODULE__{pieces: pieces, default: :identity}, x) do
    case eval(pieces, x) do
      nil -> {:ok, x}
      y -> {:ok, y}
    end
  end

  defp do_at(%__MODULE__{pieces: pieces}, x) do
    case eval(pieces, x) do
      nil -> :undefined
      y -> {:ok, y}
    end
  end

  @doc """
  Composes two warps: `compose(outer, inner)` maps `x` through `inner`
  first, then `outer` — the partial composition, defined exactly where
  `inner(x)` is defined and lands in `outer`'s domain.

  The composed warp inherits `outer`'s default.
  """
  @spec compose(t(), t()) :: t()
  def compose(%__MODULE__{pieces: :identity}, inner), do: inner
  def compose(outer, %__MODULE__{pieces: :identity}), do: outer

  def compose(%__MODULE__{pieces: outer, default: dfl}, %__MODULE__{pieces: inner}) do
    pieces =
      for {o0, o1, n0, n1} <- inner,
          {p0, p1, q0, q1} <- outer,
          lo = Coord.max(n0, p0),
          hi = Coord.min(n1, p1),
          Coord.lt?(lo, hi) do
        {lerp(lo, n0, n1, o0, o1), lerp(hi, n0, n1, o0, o1), lerp(lo, p0, p1, q0, q1),
         lerp(hi, p0, p1, q0, q1)}
      end

    %__MODULE__{pieces: sort_pieces(pieces), default: dfl}
  end

  @doc """
  Inverts a warp: new coordinates become the domain. The inverse is
  partial in both directions — coordinates outside the original images
  become undefined.
  """
  @spec invert(t()) :: t()
  def invert(%__MODULE__{pieces: :identity} = w), do: %{w | default: :undefined}

  def invert(%__MODULE__{pieces: pieces} = w) do
    %{w | pieces: pieces |> Enum.map(fn {o0, o1, n0, n1} -> {n0, n1, o0, o1} end) |> sort_pieces()}
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

  Both endpoints are cast to rational coordinates: floats are
  `{:error, {:invalid_coordinate, value}}` and `from > to` is
  `{:error, :invalid_interval}`. `map_interval!/3` is the raising
  variant.
  """
  @spec map_interval(t(), Coord.input(), Coord.input()) ::
          {:ok, interval()}
          | {:clip, [interval()], [interval()]}
          | :undefined
          | {:error, {:invalid_coordinate, term()} | :invalid_interval}
  def map_interval(warp, from, to) do
    with {:ok, from} <- Coord.cast(from),
         {:ok, to} <- Coord.cast(to),
         :ok <- check_order(from, to) do
      do_map_interval(warp, {from, to})
    end
  end

  @doc "Raising variant of `map_interval/3`, for tests and known-good inputs."
  @spec map_interval!(t(), Coord.input(), Coord.input()) ::
          {:ok, interval()} | {:clip, [interval()], [interval()]} | :undefined
  def map_interval!(warp, from, to) do
    {from, to} = cast_interval!(from, to)
    do_map_interval(warp, {from, to})
  end

  defp check_order(from, to) do
    if Coord.gt?(from, to), do: {:error, :invalid_interval}, else: :ok
  end

  defp do_map_interval(%__MODULE__{pieces: :identity}, {from, to}), do: {:ok, {from, to}}

  defp do_map_interval(%__MODULE__{pieces: pieces, default: :identity}, {from, to}) do
    covered_old =
      for {o0, o1, _n0, _n1} <- pieces,
          lo = Coord.max(o0, from),
          hi = Coord.min(o1, to),
          Coord.lte?(lo, hi),
          from == to or Coord.lt?(lo, hi) do
        {lo, hi}
      end

    case covered_old do
      [] ->
        {:ok, {from, to}}

      frags ->
        case gaps(frags, from, to) do
          [] ->
            {:ok, {eval(pieces, from), eval(pieces, to)}}

          lost ->
            covered_new = Enum.map(frags, fn {f, t} -> {eval(pieces, f), eval(pieces, t)} end)
            lost_new = Enum.map(lost, fn {f, t} -> {f, t} end)
            all = sort_intervals(covered_new ++ lost_new)
            {:clip, all, []}
        end
    end
  end

  defp do_map_interval(%__MODULE__{pieces: pieces}, {from, to}) do
    covered_old =
      for {o0, o1, _n0, _n1} <- pieces,
          lo = Coord.max(o0, from),
          hi = Coord.min(o1, to),
          Coord.lte?(lo, hi),
          from == to or Coord.lt?(lo, hi) do
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

  defp lerp(x, a0, a1, b0, b1) do
    Coord.add(b0, Coord.divide(Coord.mul(Coord.sub(x, a0), Coord.sub(b1, b0)), Coord.sub(a1, a0)))
  end

  defp cast_interval!(from, to) do
    from = Coord.cast!(from)
    to = Coord.cast!(to)

    if Coord.gt?(from, to) do
      raise ArgumentError, "interval with from > to: \#{inspect({from, to})}"
    end

    {from, to}
  end

  defp cast_segments(segments) do
    segments
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case cast_segment(segment) do
        {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      :error -> {:error, :invalid_segment}
    end
  end

  defp cast_segment({{o0, o1}, {n0, n1}}) do
    with {:ok, o0} <- Coord.cast(o0),
         {:ok, o1} <- Coord.cast(o1),
         {:ok, n0} <- Coord.cast(n0),
         {:ok, n1} <- Coord.cast(n1),
         true <- Coord.lt?(o0, o1),
         true <- Coord.lt?(n0, n1) do
      {:ok, {{o0, o1}, {n0, n1}}}
    else
      _ -> :error
    end
  end

  defp cast_segment(_), do: :error

  defp sort_pieces(pieces) do
    Enum.sort(pieces, fn {o0, _, _, _}, {p0, _, _, _} -> Coord.lte?(o0, p0) end)
  end

  defp sort_intervals(intervals) do
    Enum.sort(intervals, fn {a0, _}, {b0, _} -> Coord.lte?(a0, b0) end)
  end

  defp check_layout(pieces) do
    pieces
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [{_o0, o1, _n0, n1}, {p0, _p1, q0, _q1}], :ok ->
      cond do
        Coord.lt?(p0, o1) -> {:halt, {:error, :segments_overlap}}
        Coord.lt?(q0, n1) -> {:halt, {:error, :non_monotone}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp eval(pieces, x) do
    with {o0, o1, n0, n1} <-
           Enum.find(pieces, fn {o0, o1, _, _} -> Coord.gte?(x, o0) and Coord.lte?(x, o1) end) do
      lerp(x, o0, o1, n0, n1)
    end
  end

  defp gaps(frags, from, to) do
    {gaps, cursor} =
      Enum.map_reduce(frags, from, fn {f, t}, cursor ->
        {if(Coord.gt?(f, cursor), do: [{cursor, f}], else: []), Coord.max(cursor, t)}
      end)

    Enum.concat(gaps) ++ if(Coord.lt?(cursor, to), do: [{cursor, to}], else: [])
  end
end
