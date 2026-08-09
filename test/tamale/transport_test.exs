defmodule Tamale.TransportTest do
  use ExUnit.Case, async: true

  alias Tamale.Anchor.{Metric, Ordinal, Relative}
  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}
  alias Tamale.{Space, Transport, Warp}

  defp anchor(refs, opts \\ []) do
    %Ordinal{
      refs: refs,
      adjacent?: Keyword.get(opts, :adjacent?, false),
      at_version: Keyword.get(opts, :at_version, 0)
    }
  end

  test "unrelated edits preserve the anchor and advance at_version" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Insert{id: :c, after_id: :b})
    assert {:ok, %Ordinal{refs: [:b], at_version: 1}} = Transport.transport(anchor([:b]), s)
  end

  test "deleting a ref is terminal" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Delete{id: :b})
    assert {:undefined, {:deleted, :b}} = Transport.transport(anchor([:b]), s)
  end

  test "refs are conjunctive: losing one kills the anchor" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Delete{id: :a})
    assert {:undefined, {:deleted, :a}} = Transport.transport(anchor([:a, :b]), s)
  end

  test "split continues identity on the first child" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Split{id: :a, children: [:a, :a2]})
    assert {:ok, %Ordinal{refs: [:a]}} = Transport.transport(anchor([:a]), s)
  end

  test "merge remaps refs onto into" do
    {:ok, s} = Space.new!([:a, :b, :c]) |> Space.apply_op(%Merge{ids: [:b, :c], into: :b})
    assert {:ok, %Ordinal{refs: [:b]}} = Transport.transport(anchor([:c]), s)
  end

  test "merging two refs collapses them" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Merge{ids: [:a, :b], into: :a})
    assert {:ok, %Ordinal{refs: [:a]}} = Transport.transport(anchor([:a, :b]), s)
  end

  test "adjacent? is a head-state predicate" do
    {:ok, s} = Space.new!([:a, :b, :c]) |> Space.apply_op(%Move{id: :c, after_id: :a})
    # order is now a, c, b — refs [:a, :b] are no longer consecutive
    assert {:undefined, :adjacency_broken} =
             Transport.transport(anchor([:a, :b], adjacent?: true), s)

    assert {:ok, _} = Transport.transport(anchor([:a, :b]), s)
  end

  test "merging an adjacent? anchor's refs kills it: the boundary is gone" do
    {:ok, s} = Space.new!([:a, :b, :c]) |> Space.apply_op(%Merge{ids: [:b, :c], into: :b})

    assert {:undefined, :boundary_merged} =
             Transport.transport(anchor([:b, :c], adjacent?: true), s)
  end

  test "collapsing a middle pair kills a longer adjacent? anchor" do
    {:ok, s} = Space.new!([:a, :b, :c, :d]) |> Space.apply_op(%Merge{ids: [:b, :c], into: :b})

    assert {:undefined, :boundary_merged} =
             Transport.transport(anchor([:a, :b, :c, :d], adjacent?: true), s)
  end

  test "merging only one side slides the boundary onto into" do
    {:ok, s} = Space.new!([:a, :b, :c]) |> Space.apply_op(%Merge{ids: [:b, :c], into: :b})

    assert {:ok, %Ordinal{refs: [:a, :b], adjacent?: true, at_version: 1}} =
             Transport.transport(anchor([:a, :b], adjacent?: true), s)
  end

  test "retime is transparent to ordinal anchors" do
    {:ok, s} =
      Space.new!([:a]) |> Space.apply_op(%Retime{id: :a, old_span: {0, 10}, new_span: {5, 15}})

    assert {:ok, %Ordinal{refs: [:a]}} = Transport.transport(anchor([:a]), s)
  end

  test "transport folds multiple batches in order" do
    s = Space.new!([:a, :b])
    {:ok, s} = Space.apply_op(s, %Split{id: :b, children: [:b, :b2]})
    {:ok, s} = Space.apply_op(s, %Merge{ids: [:b, :b2], into: :b})
    assert {:ok, %Ordinal{refs: [:b], at_version: 2}} = Transport.transport(anchor([:b]), s)
  end

  test "future and truncated versions are explicit errors" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Insert{id: :b, after_id: :a})
    assert {:error, {:future_version, 99}} = Transport.transport(anchor([:a], at_version: 99), s)

    s = Space.truncate(s, 1)
    assert {:error, :log_truncated} = Transport.transport(%Ordinal{refs: [:a], at_version: 0}, s)
  end

  test "dangling refs at head are caller bugs, not silent survivors" do
    s = Space.new!([:a])
    assert {:error, {:unknown_ref, :ghost}} = Transport.transport(anchor([:ghost]), s)
  end

  test "refs born after at_version are caller bugs, not silent survivors" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Insert{id: :x, after_id: :a})
    assert {:error, {:unknown_ref, :x}} = Transport.transport(anchor([:x]), s)

    # mounted at a version where :x exists, the same ref transports fine
    assert {:ok, %Ordinal{refs: [:x], at_version: 1}} =
             Transport.transport(anchor([:x], at_version: 1), s)
  end

  test "refs born by a split after at_version are caller bugs" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Split{id: :a, children: [:a, :a2]})
    assert {:error, {:unknown_ref, :a2}} = Transport.transport(anchor([:a2]), s)
    assert {:ok, %Ordinal{refs: [:a], at_version: 1}} = Transport.transport(anchor([:a]), s)
  end

  test "non-anchor structs are reported as unsupported" do
    s = Space.new!([:a])
    assert {:error, {:unsupported_anchor, Tamale.Patch}} = Transport.transport(%Tamale.Patch{}, s)
  end

  # ---- Metric ----

  test "metric anchors need a warp provider" do
    s = Space.new!([:a])
    metric = %Metric{coord: :tick, from: 0, to: 480}
    assert {:error, :warp_provider_required} = Transport.transport(metric, s)
  end

  test "metric transport follows a retime warp" do
    {:ok, s} =
      Space.new!([:a, :b])
      |> Space.apply_op(%Retime{id: :a, old_span: {0, 10}, new_span: {0, 15}})

    # caller-side ripple: a stretches to {0, 15}, b slides to {15, 25}
    {:ok, w} = Warp.from_segments([{{0, 10}, {0, 15}}, {{10, 20}, {15, 25}}])
    provider = fn :tick, {1, _ops} -> {:ok, w} end

    metric = %Metric{coord: :tick, from: 5, to: 10, at_version: 0}

    assert {:ok, %Metric{from: {15, 2}, to: {15, 1}, at_version: 1}} =
             Transport.transport(metric, s, provider)
  end

  test "metric transport composes warps across batches" do
    s = Space.new!([:a])
    {:ok, s} = Space.apply_op(s, %Retime{id: :a, old_span: {0, 10}, new_span: {0, 20}})
    {:ok, s} = Space.apply_op(s, %Retime{id: :a, old_span: {0, 20}, new_span: {10, 20}})

    provider = fn
      :tick, {1, _ops} -> {:ok, Warp.from_span({0, 10}, {0, 20})}
      :tick, {2, _ops} -> {:ok, Warp.from_span({0, 20}, {10, 20})}
    end

    metric = %Metric{coord: :tick, from: 0, to: 10, at_version: 0}

    assert {:ok, %Metric{from: {10, 1}, to: {20, 1}, at_version: 2}} =
             Transport.transport(metric, s, provider)
  end

  test "metric transport clips when part of the support is deleted" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Delete{id: :b})

    # b spanned {10, 20}; nothing follows, so the warp only covers a
    provider = fn :tick, _entry -> {:ok, Warp.from_span({0, 10}, {0, 10})} end
    metric = %Metric{coord: :tick, from: 5, to: 15, at_version: 0}

    assert {:clip, [%Metric{from: {5, 1}, to: {10, 1}, at_version: 1}], [{{10, 1}, {15, 1}}]} =
             Transport.transport(metric, s, provider)
  end

  test "metric transport is undefined when the support leaves the warp domain" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Delete{id: :b})
    provider = fn :tick, _entry -> {:ok, Warp.from_span({0, 10}, {0, 10})} end
    metric = %Metric{coord: :tick, from: 10, to: 20, at_version: 0}
    assert {:undefined, :outside_warp} = Transport.transport(metric, s, provider)
  end

  test "metric anchor at head is returned normalized and the provider is not called" do
    s = Space.new!([:a])
    metric = %Metric{coord: :tick, from: 3, to: 8, at_version: 0}
    provider = fn _coord, _entry -> raise "provider must not be called" end

    assert {:ok, %Metric{from: {3, 1}, to: {8, 1}, at_version: 0}} =
             Transport.transport(metric, s, provider)
  end

  test "metric anchors reject float endpoints and inverted intervals" do
    s = Space.new!([:a])
    provider = fn _coord, _entry -> {:ok, Warp.identity()} end

    assert {:error, {:invalid_coordinate, 0.5}} =
             Transport.transport(%Metric{coord: :tick, from: 0.5, to: 8}, s, provider)

    assert {:error, :invalid_interval} =
             Transport.transport(%Metric{coord: :tick, from: 8, to: 3}, s, provider)
  end

  test "fold_warp returns exactly the warp transport folds" do
    s = Space.new!([:a])
    {:ok, s} = Space.apply_op(s, %Retime{id: :a, old_span: {0, 10}, new_span: {0, 20}})
    {:ok, s} = Space.apply_op(s, %Retime{id: :a, old_span: {0, 20}, new_span: {10, 20}})

    provider = fn
      :tick, {1, _ops} -> {:ok, Warp.from_span({0, 10}, {0, 20})}
      :tick, {2, _ops} -> {:ok, Warp.from_span({0, 20}, {10, 20})}
    end

    # same composed warp as "metric transport composes warps across batches"
    assert {:ok, warp} = Transport.fold_warp(:tick, s, 0, provider)
    assert {:ok, {15, 1}} = Warp.at(warp, 5)
    assert {:ok, {20, 1}} = Warp.at(warp, 10)
  end

  test "provider error aborts the fold and surfaces as the transport result" do
    s = Space.new!([:a])
    {:ok, s} = Space.apply_op(s, %Retime{id: :a, old_span: {0, 10}, new_span: {0, 20}})

    provider = fn :tick, _entry -> {:error, :warp_construction_failed} end

    assert {:error, :warp_construction_failed} = Transport.fold_warp(:tick, s, 0, provider)

    metric = %Metric{coord: :tick, from: 0, to: 5, at_version: 0}
    assert {:error, :warp_construction_failed} = Transport.transport(metric, s, provider)
  end

  test "fold_warp at head is identity and reports version errors" do
    {:ok, s} =
      Space.new!([:a]) |> Space.apply_op(%Retime{id: :a, old_span: {0, 10}, new_span: {0, 20}})

    provider = fn :tick, _entry -> {:ok, Warp.from_span({0, 10}, {0, 20})} end

    assert {:ok, warp} = Transport.fold_warp(:tick, s, 1, provider)
    assert warp == Warp.identity()

    assert {:error, {:future_version, 99}} = Transport.fold_warp(:tick, s, 99, provider)

    s = Space.truncate(s, 1)
    assert {:error, :log_truncated} = Transport.fold_warp(:tick, s, 0, provider)
  end

  # ---- Relative ----

  test "relative anchor survives unrelated edits and tracks at_version" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Insert{id: :c, after_id: :b})
    anchor = %Relative{ref: :b, from_offset: -5, to_offset: 10, at_version: 0}

    assert {:ok, %Relative{ref: :b, from_offset: {-5, 1}, to_offset: {10, 1}, at_version: 1}} =
             Transport.transport(anchor, s)
  end

  test "relative anchors reject float offsets" do
    s = Space.new!([:a])
    anchor = %Relative{ref: :a, from_offset: 0, to_offset: 0.05}

    assert {:error, {:invalid_coordinate, 0.05}} = Transport.transport(anchor, s)
  end

  test "relative anchor dies with its host" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Delete{id: :a})
    anchor = %Relative{ref: :a, from_offset: 0, to_offset: 10, at_version: 0}
    assert {:undefined, {:deleted, :a}} = Transport.transport(anchor, s)
  end

  test "relative anchor follows the first child on split" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Split{id: :a, children: [:a, :a2]})
    anchor = %Relative{ref: :a, from_offset: 0, to_offset: 10, at_version: 0}
    assert {:ok, %Relative{ref: :a, at_version: 1}} = Transport.transport(anchor, s)
  end

  test "relative anchor re-derives its interval from the host's new span after retime" do
    {:ok, s} =
      Space.new!([:a])
      |> Space.apply_op(%Retime{id: :a, old_span: {100, 200}, new_span: {150, 250}})

    anchor = %Relative{ref: :a, from_offset: -30, to_offset: 10, at_version: 0}
    assert {:ok, transported} = Transport.transport(anchor, s)

    span_fun = fn :a -> {150, 250} end

    assert {:ok, %Metric{from: {120, 1}, to: {160, 1}}} =
             Tamale.Anchor.project(transported, :tick, span_fun)
  end
end
