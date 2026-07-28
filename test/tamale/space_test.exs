defmodule Tamale.SpaceTest do
  use ExUnit.Case, async: true

  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}
  alias Tamale.Space

  test "genesis" do
    s = Space.new!([:a, :b])
    assert s.ids == [:a, :b]
    assert s.version == 0
    assert s.log == []
  end

  test "genesis rejects duplicate ids" do
    assert {:error, :duplicate_ids} = Space.new([:a, :a])
    assert_raise ArgumentError, fn -> Space.new!([:a, :a]) end
  end

  test "a batch bumps version once and appends one log entry" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_batch([%Insert{id: :b, after_id: :a}])
    assert s.ids == [:a, :b]
    assert s.version == 1
    assert [{1, [%Insert{id: :b}]}] = s.log
  end

  test "a batch is atomic: one bad op rejects the whole batch" do
    s = Space.new!([:a])

    assert {:error, {:unknown_id, :ghost}} =
             Space.apply_batch(s, [%Insert{id: :b, after_id: :a}, %Delete{id: :ghost}])

    assert s.ids == [:a]
    assert s.version == 0
  end

  test "insert at head" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Insert{id: :z, after_id: :head})
    assert s.ids == [:z, :a]
  end

  test "deleted ids are never reused" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Delete{id: :b})
    assert {:error, {:id_reused, :b}} = Space.apply_op(s, %Insert{id: :b, after_id: :a})
  end

  test "duplicate active ids are rejected" do
    s = Space.new!([:a])
    assert {:error, {:duplicate_id, :a}} = Space.apply_op(s, %Insert{id: :a, after_id: :head})
  end

  test "split splices children in place, first child keeps the id" do
    {:ok, s} = Space.new!([:a, :b]) |> Space.apply_op(%Split{id: :a, children: [:a, :a2]})
    assert s.ids == [:a, :a2, :b]
  end

  test "split with a foreign first child is rejected" do
    s = Space.new!([:a])
    assert {:error, :split_identity} = Space.apply_op(s, %Split{id: :a, children: [:x, :y]})
  end

  test "merge collapses the tail ids into the first" do
    {:ok, s} = Space.new!([:a, :b, :c]) |> Space.apply_op(%Merge{ids: [:a, :b], into: :a})
    assert s.ids == [:a, :c]
  end

  test "merge requires adjacency and into == hd(ids)" do
    s = Space.new!([:a, :b, :c])
    assert {:error, :merge_not_adjacent} = Space.apply_op(s, %Merge{ids: [:a, :c], into: :a})
    assert {:error, :merge_into} = Space.apply_op(s, %Merge{ids: [:a, :b], into: :b})
  end

  test "move reorders" do
    {:ok, s} = Space.new!([:a, :b, :c]) |> Space.apply_op(%Move{id: :a, after_id: :c})
    assert s.ids == [:b, :c, :a]
  end

  test "retime leaves order untouched but validates spans" do
    s = Space.new!([:a])

    assert {:ok, %{ids: [:a]}} =
             Space.apply_op(s, %Retime{id: :a, old_span: {0, 10}, new_span: {0, 20}})

    assert {:error, :invalid_span} =
             Space.apply_op(s, %Retime{id: :a, old_span: {0, 10}, new_span: {20, 10}})
  end

  test "retime accepts rational spans and rejects floats" do
    s = Space.new!([:a])

    assert {:ok, _} =
             Space.apply_op(s, %Retime{id: :a, old_span: {0, {3, 1}}, new_span: {0, {1, 1}}})

    assert {:error, :invalid_span} =
             Space.apply_op(s, %Retime{id: :a, old_span: {0.0, 10}, new_span: {0, 20}})
  end

  test "truncate hides history below the base version" do
    {:ok, s} = Space.new!([:a]) |> Space.apply_op(%Insert{id: :b, after_id: :a})
    s = Space.truncate(s, 1)
    assert {:error, :log_truncated} = Space.log_from(s, 0)
    assert {:ok, []} = Space.log_from(s, 1)
  end

  test "log_from reports future versions" do
    s = Space.new!([:a])
    assert {:error, {:future_version, 1}} = Space.log_from(s, 1)
  end
end
