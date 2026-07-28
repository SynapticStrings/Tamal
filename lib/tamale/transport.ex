defmodule Tamale.Transport do
  @moduledoc """
  Anchor transport along the op log — the whole of rebase.

      transport(anchor, space) = fold(anchor, log[anchor.at_version..head])

  The result is three-valued, matching the three shapes a morphism between
  two space versions can take — plus a first-class fourth for partial
  survival, which only `Anchor.Metric` can produce:

  - `{:ok, anchor'}` — well-defined
  - `{:clip, covered, lost}` — part of the support survived (Metric only):
    `covered` are the surviving image anchors, `lost` the old-coordinate
    sub-intervals with no image. How much loss is tolerable is the
    channel's call, so the kernel surfaces it verbatim.
  - `{:ambiguous, candidates}` — one-to-many; a policy choice is required.
    Not produced by the kernel's own conventions (they are deliberately
    deterministic); reserved so policy layers share the result type.
  - `{:undefined, reason}` — the referent is gone

  ## Ordinal semantics

  - refs are conjunctive: `Delete` of any ref is terminal
  - `Split` continues identity on the first child (kernel convention)
  - `Merge` remaps refs onto `into`
  - `adjacent?` is judged on the **head state** after the fold. ids are
    never reused and deletes are irreversible, so only the net effect can
    matter — a mid-log break that is restored by head leaves no residue.
  - refs that are not live at head indicate a Caller bug at mount time and
    are reported as `{:error, {:unknown_ref, id}}`, not silently kept

  ## Metric semantics

  Metric anchors travel by warp, not by identity. The kernel holds no
  element spans and no tempo map, so the Caller supplies a
  `warp_provider` — `(coord, log_entry) -> Warp.t()` — and transport folds
  the per-entry warps into one (`Warp.compose/2`, oldest first), then maps
  the anchor interval through it (`Warp.map_interval/2`):

  - full coverage → `{:ok, anchor'}` (including being stretched over an
    insertion)
  - partial coverage → `{:clip, [%Anchor.Metric{}], lost}`
  - no coverage → `{:undefined, :outside_warp}`

  ## Relative semantics

  A Relative anchor is its host ref: transported with Ordinal rules,
  offsets untouched (a host stretch does not rescale "0–50 ms after the
  start"). The absolute interval is derived at use time from the host's
  current span — see `Tamale.Anchor.project/3`. Offsets may be negative
  and may overhang the host; there is no within-host invariant.
  """

  alias Tamale.{Anchor, Space, Warp}
  alias Tamale.Anchor.{Metric, Ordinal, Relative}
  alias Tamale.Op.{Delete, Merge, Split}

  @typedoc "Supplies the warp for one log entry in one coordinate system."
  @type warp_provider :: (term(), Space.entry() -> Warp.t())

  @type result ::
          {:ok, Anchor.t()}
          | {:clip, [Metric.t()], [Warp.interval()]}
          | {:ambiguous, [Anchor.t()]}
          | {:undefined, term()}

  @spec transport(Anchor.t(), Space.t()) :: result() | {:error, term()}
  def transport(anchor, space)

  def transport(%Ordinal{at_version: v} = anchor, %Space{} = space) do
    with {:ok, entries} <- Space.log_from(space, v) do
      entries
      |> Enum.flat_map(fn {_v, ops} -> ops end)
      |> Enum.reduce_while({:ok, anchor.refs}, fn op, {:ok, refs} ->
        case remap(refs, op) do
          {:ok, refs2} -> {:cont, {:ok, refs2}}
          {:undefined, _} = undef -> {:halt, undef}
        end
      end)
      |> case do
        {:ok, refs} -> finish(%{anchor | refs: refs, at_version: space.version}, space)
        other -> other
      end
    end
  end

  def transport(%Relative{ref: ref} = anchor, %Space{} = space) do
    probe = %Ordinal{refs: [ref], at_version: anchor.at_version}

    case transport(probe, space) do
      {:ok, %Ordinal{refs: [ref], at_version: v}} -> {:ok, %{anchor | ref: ref, at_version: v}}
      other -> other
    end
  end

  def transport(%Metric{}, %Space{}) do
    {:error, :warp_provider_required}
  end

  def transport(%_{} = unsupported, %Space{}) do
    {:error, {:unsupported_anchor, unsupported.__struct__}}
  end

  @doc """
  Transports a `Tamale.Anchor.Metric` along the log, folding the warps the
  provider supplies for each entry (`coord` is passed through so one
  provider can serve several coordinate systems).
  """
  @spec transport(Metric.t(), Space.t(), warp_provider()) :: result() | {:error, term()}
  def transport(%Metric{coord: coord} = anchor, %Space{} = space, warp_provider)
      when is_function(warp_provider, 2) do
    with {:ok, entries} <- Space.log_from(space, anchor.at_version) do
      total =
        Enum.reduce(entries, Warp.identity(), fn entry, acc ->
          Warp.compose(warp_provider.(coord, entry), acc)
        end)

      case Warp.map_interval(total, anchor.from, anchor.to) do
        {:ok, {from, to}} ->
          {:ok, %{anchor | from: from, to: to, at_version: space.version}}

        {:clip, covered, lost} ->
          anchors =
            Enum.map(covered, fn {from, to} ->
              %Metric{coord: coord, from: from, to: to, at_version: space.version}
            end)

          {:clip, anchors, lost}

        :undefined ->
          {:undefined, :outside_warp}
      end
    end
  end

  # ---- per-op ref remapping ----

  defp remap(refs, %Delete{id: id}) do
    if id in refs, do: {:undefined, {:deleted, id}}, else: {:ok, refs}
  end

  defp remap(refs, %Split{id: id, children: [first | _]}) do
    {:ok, Enum.map(refs, fn r -> if r == id, do: first, else: r end)}
  end

  defp remap(refs, %Merge{ids: merge_ids, into: into}) do
    {refs2, _done?} =
      Enum.reduce(refs, {[], false}, fn r, {acc, done?} ->
        cond do
          r not in merge_ids -> {[r | acc], done?}
          done? -> {acc, true}
          true -> {[into | acc], true}
        end
      end)

    {:ok, Enum.reverse(refs2)}
  end

  # Insert / Move / Retime leave identity refs untouched.
  defp remap(refs, _op), do: {:ok, refs}

  # ---- head-state checks ----

  defp finish(%Ordinal{refs: refs} = anchor, space) do
    case Enum.find(refs, &(&1 not in space.ids)) do
      nil ->
        if anchor.adjacent? and not consecutive?(refs, space.ids) do
          {:undefined, :adjacency_broken}
        else
          {:ok, anchor}
        end

      bad ->
        {:error, {:unknown_ref, bad}}
    end
  end

  defp consecutive?([], _ids), do: true

  defp consecutive?(refs, ids) do
    idx = refs |> Enum.map(fn r -> Enum.find_index(ids, &(&1 == r)) end) |> Enum.sort()
    [first | _] = idx
    idx == Enum.to_list(first..(first + length(idx) - 1))
  end
end
