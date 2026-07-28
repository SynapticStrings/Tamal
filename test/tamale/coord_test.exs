defmodule Tamale.CoordTest do
  use ExUnit.Case, async: true

  alias Tamale.Coord

  test "new/2 normalizes: gcd reduction, sign to the numerator, zero canonical" do
    assert Coord.new(2, 4) == {1, 2}
    assert Coord.new(1, -2) == {-1, 2}
    assert Coord.new(-6, -9) == {2, 3}
    assert Coord.new(0, 5) == {0, 1}
  end

  test "new/2 raises on a zero denominator" do
    assert_raise ArgumentError, fn -> Coord.new(1, 0) end
  end

  test "cast accepts integers and pairs, rejects floats and junk" do
    assert Coord.cast(4) == {:ok, {4, 1}}
    assert Coord.cast({2, 4}) == {:ok, {1, 2}}
    assert Coord.cast(0.5) == {:error, {:invalid_coordinate, 0.5}}
    assert Coord.cast({1, 0}) == {:error, {:invalid_coordinate, {1, 0}}}
    assert Coord.cast("1/2") == {:error, {:invalid_coordinate, "1/2"}}
  end

  test "cast! raises on invalid data" do
    assert Coord.cast!(4) == {4, 1}
    # dyn/1 hides the literal from the type checker — the float is
    # deliberately outside the typed contract to test the runtime guard
    assert_raise ArgumentError, fn -> Coord.cast!(dyn(0.5)) end
  end

  defp dyn(x), do: x

  test "arithmetic is exact" do
    third = Coord.new(1, 3)
    sixth = Coord.new(1, 6)

    assert Coord.add(third, sixth) == {1, 2}
    assert Coord.sub(third, sixth) == {1, 6}
    assert Coord.mul(third, sixth) == {1, 18}
    assert Coord.divide(third, sixth) == {2, 1}
    assert Coord.negate(third) == {-1, 3}
    assert Coord.add({3, 1}, {1, 2}) == {7, 2}
  end

  test "divide by zero raises" do
    assert_raise ArgumentError, fn -> Coord.divide({1, 1}, {0, 1}) end
  end

  test "compare works across denominators" do
    assert Coord.compare({1, 3}, {1, 2}) == :lt
    assert Coord.compare({2, 4}, {1, 2}) == :eq
    assert Coord.compare({3, 1}, {5, 2}) == :gt
    assert Coord.lt?({-1, 2}, {0, 1})
    assert Coord.lte?({1, 2}, {1, 2})
    assert Coord.max({1, 3}, {1, 2}) == {1, 2}
    assert Coord.min({1, 3}, {1, 2}) == {1, 3}
  end

  test "wire form: integers when whole, p/q strings otherwise" do
    assert Coord.encode({4, 1}) == 4
    assert Coord.encode({4, 3}) == "4/3"
    assert Coord.encode({-7, 2}) == "-7/2"
  end

  test "decode parses the wire form and rejects floats and malformed strings" do
    assert Coord.decode(4) == {:ok, {4, 1}}
    assert Coord.decode("4/3") == {:ok, {4, 3}}
    assert Coord.decode("-7/2") == {:ok, {-7, 2}}
    assert Coord.decode("2/4") == {:ok, {1, 2}}
    assert Coord.decode(0.5) == {:error, {:invalid_coordinate, 0.5}}
    assert Coord.decode("1/0") == {:error, {:invalid_coordinate, "1/0"}}
    assert Coord.decode("abc") == {:error, {:invalid_coordinate, "abc"}}
    assert Coord.decode("1/2/3") == {:error, {:invalid_coordinate, "1/2/3"}}
  end

  test "encode/decode round-trips" do
    for coord <- [{4, 1}, {1, 3}, {-2, 25}, {0, 1}] do
      assert {:ok, ^coord} = coord |> Coord.encode() |> Coord.decode()
    end
  end
end
