defmodule Tamale.Space do
  @moduledoc """
  A versioned identity space: an ordered set of element ids, an append-only
  op log, and nothing else.

  - ids are stable and **never reused** — a deleted id stays dead, so a
    historical anchor can never resurrect onto a new element
  - every write is an `Tamale.Op` batch; a batch is atomic and bumps
    `version` by one, appending one log entry
  - the Space holds **no domain data** — element payloads (notes,
    phonemes, frames) live in Caller-side tables keyed by id

  The log doubles as the tombstone record: anchors carry `at_version` and
  are transported along `log[at_version..head]` (`Tamale.Transport`), so
  `truncate/2` below the oldest live anchor version replaces
  reference-counted GC. Single-writer assumption: one linear log, no
  branching. (Concurrent/offline editing would reintroduce tombstones —
  as a deliberate kernel extension, not a heuristic.)

  Note: `log` is a plain list appended at the end (O(n) per batch). Fine
  at scaffold scale; a production Space can swap in a queue without
  changing semantics.
  """

  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}

  @typedoc "One log entry: the version a batch produced, and its ops."
  @type entry :: {Tamale.version(), [Tamale.Op.t()]}

  @type t :: %__MODULE__{
          ids: [Tamale.id()],
          version: Tamale.version(),
          log: [entry()],
          base_version: Tamale.version(),
          seen: MapSet.t(Tamale.id())
        }

  defstruct ids: [], version: 0, log: [], base_version: 0, seen: MapSet.new()

  @doc "Creates a space. Genesis ids are active at version 0."
  @spec new([Tamale.id()]) :: t()
  def new(ids \\ []) when is_list(ids) do
    if length(ids) == length(Enum.uniq(ids)) do
      %__MODULE__{ids: ids, seen: MapSet.new(ids)}
    else
      raise ArgumentError, "duplicate ids in genesis"
    end
  end

  @doc "Applies a single op. Sugar for `apply_batch(space, [op])`."
  @spec apply_op(t(), Tamale.Op.t()) :: {:ok, t()} | {:error, term()}
  def apply_op(space, op), do: apply_batch(space, [op])

  @doc """
  Applies a batch atomically: each op validates against the running state;
  all land or none. On success bumps `version` and appends one log entry.
  """
  @spec apply_batch(t(), [Tamale.Op.t()]) :: {:ok, t()} | {:error, term()}
  def apply_batch(%__MODULE__{} = space, []), do: {:ok, space}

  def apply_batch(%__MODULE__{} = space, ops) when is_list(ops) do
    with {:ok, ids, seen} <- run_ops(space, ops) do
      v = space.version + 1
      {:ok, %{space | ids: ids, seen: seen, version: v, log: space.log ++ [{v, ops}]}}
    end
  end

  @doc "Whether `id` is currently active."
  @spec member?(t(), Tamale.id()) :: boolean()
  def member?(%__MODULE__{ids: ids}, id), do: id in ids

  @doc """
  Log entries with version > `from_version`, oldest first.

  Errors are explicit: `{:future_version, v}` if `from_version` is ahead of
  head, `:log_truncated` if the needed history was dropped by `truncate/2`.
  """
  @spec log_from(t(), Tamale.version()) :: {:ok, [entry()]} | {:error, term()}
  def log_from(%__MODULE__{} = space, from_version) do
    cond do
      from_version > space.version -> {:error, {:future_version, from_version}}
      from_version < space.base_version -> {:error, :log_truncated}
      true -> {:ok, Enum.filter(space.log, fn {v, _ops} -> v > from_version end)}
    end
  end

  @doc """
  Drops log entries at or below `oldest_live_version` — the log-age
  equivalent of GC. Anchors older than that horizon can no longer be
  transported (`log_from/2` reports `:log_truncated`).
  """
  @spec truncate(t(), Tamale.version()) :: t()
  def truncate(%__MODULE__{} = space, oldest_live_version) do
    v = min(max(oldest_live_version, space.base_version), space.version)
    %{space | base_version: v, log: Enum.filter(space.log, fn {ev, _} -> ev > v end)}
  end

  # ---- op application ----

  defp run_ops(space, ops) do
    Enum.reduce_while(ops, {:ok, space.ids, space.seen}, fn op, {:ok, ids, seen} ->
      case apply_one(ids, seen, op) do
        {:ok, ids2, seen2} -> {:cont, {:ok, ids2, seen2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_one(ids, seen, %Insert{id: id, after_id: at}) do
    cond do
      MapSet.member?(seen, id) and id in ids -> {:error, {:duplicate_id, id}}
      MapSet.member?(seen, id) -> {:error, {:id_reused, id}}
      at != :head and at not in ids -> {:error, {:unknown_id, at}}
      true -> {:ok, insert_after(ids, at, id), MapSet.put(seen, id)}
    end
  end

  defp apply_one(ids, seen, %Delete{id: id}) do
    if id in ids, do: {:ok, List.delete(ids, id), seen}, else: {:error, {:unknown_id, id}}
  end

  defp apply_one(ids, seen, %Split{id: id, children: children}) do
    rest = Enum.drop(children, 1)
    reused = Enum.find(rest, &MapSet.member?(seen, &1))

    cond do
      id not in ids ->
        {:error, {:unknown_id, id}}

      length(children) < 2 ->
        {:error, :split_trivial}

      hd(children) != id ->
        {:error, :split_identity}

      length(children) != length(Enum.uniq(children)) ->
        {:error, :split_duplicate_children}

      reused != nil ->
        {:error, {:id_reused, reused}}

      true ->
        ids2 = Enum.flat_map(ids, fn x -> if x == id, do: children, else: [x] end)
        {:ok, ids2, Enum.reduce(rest, seen, &MapSet.put(&2, &1))}
    end
  end

  defp apply_one(ids, seen, %Merge{ids: merge_ids, into: into}) do
    unknown = Enum.find(merge_ids, &(&1 not in ids))

    cond do
      length(merge_ids) < 2 -> {:error, :merge_trivial}
      into != hd(merge_ids) -> {:error, :merge_into}
      unknown != nil -> {:error, {:unknown_id, unknown}}
      not adjacent_run?(ids, merge_ids) -> {:error, :merge_not_adjacent}
      true -> {:ok, ids -- tl(merge_ids), seen}
    end
  end

  defp apply_one(ids, seen, %Move{id: id, after_id: at}) do
    cond do
      id not in ids -> {:error, {:unknown_id, id}}
      at == id -> {:error, :move_self}
      at != :head and at not in ids -> {:error, {:unknown_id, at}}
      at == :head -> {:ok, [id | List.delete(ids, id)], seen}
      true -> {:ok, insert_after(List.delete(ids, id), at, id), seen}
    end
  end

  defp apply_one(ids, seen, %Retime{id: id, old_span: old, new_span: new}) do
    cond do
      id not in ids -> {:error, {:unknown_id, id}}
      not valid_span?(old) or not valid_span?(new) -> {:error, :invalid_span}
      true -> {:ok, ids, seen}
    end
  end

  # ---- helpers ----

  defp insert_after(ids, :head, id), do: [id | ids]

  defp insert_after(ids, at, id) do
    Enum.flat_map(ids, fn x -> if x == at, do: [x, id], else: [x] end)
  end

  defp adjacent_run?(ids, run) do
    ids
    |> Enum.chunk_every(length(run), 1, :discard)
    |> Enum.member?(run)
  end

  defp valid_span?({s, e}), do: is_number(s) and is_number(e) and s < e
  defp valid_span?(_), do: false
end
