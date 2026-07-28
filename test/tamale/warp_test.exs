defmodule Tamale.WarpTest do
  use ExUnit.Case, async: true

  alias Tamale.Warp

  test "identity maps every coordinate to itself" do
    assert {:ok, 42} = Warp.at(Warp.identity(), 42)
  end

  test "a single piece is linear inside and undefined outside" do
    w = Warp.from_span({0, 10}, {100, 200})
    assert {:ok, 150.0} = Warp.at(w, 5)
    assert :undefined = Warp.at(w, 11)
  end

  test "from_segments normalizes order and accepts abutting segments" do
    assert {:ok, w} = Warp.from_segments([{{10, 20}, {10, 20}}, {{0, 10}, {0, 10}}])
    assert {:ok, 5.0} = Warp.at(w, 5)
    assert {:ok, 15.0} = Warp.at(w, 15)
    assert :undefined = Warp.at(w, 25)
  end

  test "from_segments rejects bad shapes, overlaps and non-monotone images" do
    assert {:error, :invalid_segment} = Warp.from_segments([{{0, 10}, {5, 5}}])
    assert {:error, :invalid_segment} = Warp.from_segments([{{10, 0}, {0, 10}}])

    assert {:error, :segments_overlap} =
             Warp.from_segments([{{0, 15}, {0, 15}}, {{10, 20}, {20, 30}}])

    assert {:error, :non_monotone} =
             Warp.from_segments([{{0, 10}, {10, 20}}, {{10, 20}, {0, 10}}])
  end

  test "compose applies inner then outer, defined on the intersection" do
    inner = Warp.from_span({0, 10}, {0, 20})
    outer = Warp.from_span({10, 30}, {100, 160})
    w = Warp.compose(outer, inner)

    assert :undefined = Warp.at(w, 4)
    assert {:ok, 100.0} = Warp.at(w, 5)
    assert {:ok, 130.0} = Warp.at(w, 10)
  end

  test "identity composes transparently on both sides" do
    w = Warp.from_span({0, 10}, {5, 25})
    assert w == Warp.compose(Warp.identity(), w)
    assert w == Warp.compose(w, Warp.identity())
  end

  test "invert round-trips defined points and is partial" do
    w = Warp.from_span({0, 10}, {100, 200})
    inv = Warp.invert(w)

    assert {:ok, 5.0} = Warp.at(inv, 150)
    assert :undefined = Warp.at(inv, 50)
    assert Warp.invert(Warp.identity()) == Warp.identity()
  end

  test "map_interval covers fully across abutting pieces" do
    {:ok, w} = Warp.from_segments([{{0, 10}, {0, 10}}, {{10, 20}, {10, 30}}])

    assert {:ok, {from, 30.0}} = Warp.map_interval(w, 0, 20)
    assert from == 0

    assert {:ok, {5.0, 20.0}} = Warp.map_interval(w, 5, 15)
  end

  test "map_interval stretches over an insertion jump" do
    {:ok, w} = Warp.from_segments([{{0, 10}, {0, 10}}, {{10, 20}, {30, 40}}])
    assert {:ok, {5.0, 35.0}} = Warp.map_interval(w, 5, 15)
  end

  test "map_interval clips with covered images and lost old intervals" do
    # ripple delete of [10, 20]: [20, 30] slides down to [10, 20]
    {:ok, w} = Warp.from_segments([{{0, 10}, {0, 10}}, {{20, 30}, {10, 20}}])
    assert {:clip, [{5.0, 10.0}, {10.0, 15.0}], [{10, 20}]} = Warp.map_interval(w, 5, 25)
  end

  test "map_interval reports every hole in the support" do
    {:ok, w} =
      Warp.from_segments([{{0, 10}, {0, 10}}, {{20, 30}, {10, 20}}, {{40, 50}, {20, 30}}])

    assert {:clip, _, [{10, 20}, {30, 40}]} = Warp.map_interval(w, 0, 50)
  end

  test "map_interval: boundary-touching coverage alone is undefined" do
    w = Warp.from_span({0, 10}, {0, 10})
    assert :undefined = Warp.map_interval(w, 10, 20)
    assert :undefined = Warp.map_interval(w, 20, 30)
  end

  test "map_interval: identity covers everything, points work" do
    assert {:ok, {7, 9}} = Warp.map_interval(Warp.identity(), 7, 9)
    assert {:ok, {5.0, 5.0}} = Warp.map_interval(Warp.from_span({0, 10}, {0, 10}), 5, 5)
  end
end
