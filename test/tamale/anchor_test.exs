defmodule Tamale.AnchorTest do
  use ExUnit.Case, async: true

  alias Tamale.Anchor
  alias Tamale.Anchor.{Metric, Relative}

  test "project derives an absolute interval from the host span" do
    anchor = %Relative{ref: :phoneme_3, from_offset: 0, to_offset: 50, at_version: 2}
    span_fun = fn :phoneme_3 -> {1000, 1200} end

    assert {:ok, %Metric{coord: :ms, from: 1000, to: 1050, at_version: 2}} =
             Anchor.project(anchor, :ms, span_fun)
  end

  test "project allows negative offsets overhanging the host (preutterance)" do
    anchor = %Relative{ref: :phoneme_3, from_offset: -80, to_offset: 20}
    span_fun = fn :phoneme_3 -> {1000, 1200} end

    assert {:ok, %Metric{from: 920, to: 1020}} = Anchor.project(anchor, :ms, span_fun)
  end

  test "project reports unknown hosts" do
    anchor = %Relative{ref: :ghost, from_offset: 0, to_offset: 10}

    assert {:error, {:unknown_id, :ghost}} = Anchor.project(anchor, :ms, fn _ -> nil end)
  end
end
