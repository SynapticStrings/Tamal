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

  ## Algebra

  - `from_segments/1` — piecewise assembly from `{old_span, new_span}`
    segment pairs (the only raw material is coordinate data; turning tempo
    maps or element span tables into segments is the adapter layer's job)
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

  @type t :: %__MODULE__{pieces: :identity | [piece()]}

  defstruct pieces: :identity

  @doc "The identity warp: every coordinate maps to itself."
  @spec identity() :: t()
  def identity, do: %__MODULE__{}

  @doc """
  A single-piece warp linearly mapping `old_span` onto `new_span`.

  This is the literal form for hand-written warps: endpoints are cast with
  `Coord.cast!/1` and a non-increasing span raises `ArgumentError`. For
  data-driven assembly use `from_segments/1`, which returns errors.
  """
  @spec from_span({Coord.input(), Coord.input()}, {Coord.input(), Coord.input()}) :: t()
  def from_span({o0, o1} = old_span, {n0, n1} = new_span) do
    o0 = Coord.cast!(o0)
    o1 = Coord.cast!(o1)
    n0 = Coord.cast!(n0)
    n1 = Coord.cast!(n1)

    unless Coord.lt?(o0, o1) and Coord.lt?(n0, n1) do
      raise ArgumentError, "invalid warp span: #{inspect({old_span, new_span})}"
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
  Where did coordinate `x` go? `:undefined` outside all pieces. `x` is
  cast with `Coord.cast!/1`; the result is always a normalized rational.
  """
  @spec at(t(), Coord.input()) :: {:ok, Coord.t()} | :undefined
  def at(%__MODULE__{pieces: :identity}, x), do: {:ok, Coord.cast!(x)}

  def at(%__MODULE__{pieces: pieces}, x) do
    case eval(pieces, Coord.cast!(x)) do
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
          lo = Coord.max(n0, p0),
          hi = Coord.min(n1, p1),
          Coord.lt?(lo, hi) do
        {lerp(lo, n0, n1, o0, o1), lerp(hi, n0, n1, o0, o1), lerp(lo, p0, p1, q0, q1),
         lerp(hi, p0, p1, q0, q1)}
      end

    %__MODULE__{pieces: sort_pieces(pieces)}
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
      pieces: pieces |> Enum.map(fn {o0, o1, n0, n1} -> {n0, n1, o0, o1} end) |> sort_pieces()
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
  endpoint) does not count as coverage. Both endpoints are cast with
  `Coord.cast!/1`; `from > to` raises `ArgumentError`.
  """
  @spec map_interval(t(), Coord.input(), Coord.input()) ::
          {:ok, interval()} | {:clip, [interval()], [interval()]} | :undefined
  def map_interval(%__MODULE__{pieces: :identity}, from, to) do
    {:ok, cast_interval!(from, to)}
  end

  def map_interval(%__MODULE__{pieces: pieces}, from, to) do
    {from, to} = cast_interval!(from, to)

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

  # Maps x linearly from span {a0, a1} onto span {b0, b1}. Exact: every
  # operation stays in the rationals.
  defp lerp(x, a0, a1, b0, b1) do
    Coord.add(b0, Coord.divide(Coord.mul(Coord.sub(x, a0), Coord.sub(b1, b0)), Coord.sub(a1, a0)))
  end

  defp cast_interval!(from, to) do
    from = Coord.cast!(from)
    to = Coord.cast!(to)

    if Coord.gt?(from, to) do
      raise ArgumentError, "interval with from > to: #{inspect({from, to})}"
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

  # Sub-intervals of `[from, to]` not covered by the sorted fragment list.
  defp gaps(frags, from, to) do
    {gaps, cursor} =
      Enum.map_reduce(frags, from, fn {f, t}, cursor ->
        {if(Coord.gt?(f, cursor), do: [{cursor, f}], else: []), Coord.max(cursor, t)}
      end)

    Enum.concat(gaps) ++ if(Coord.lt?(cursor, to), do: [{cursor, to}], else: [])
  end
end
