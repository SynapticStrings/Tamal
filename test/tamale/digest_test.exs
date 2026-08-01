defmodule Tamale.DigestTest do
  use ExUnit.Case, async: true

  alias Tamale.Digest

  defp encoded!(term) do
    {:ok, iodata} = Digest.encode(term)
    IO.iodata_to_binary(iodata)
  end

  describe "canonical encoding" do
    test "scalars" do
      assert encoded!(nil) == "null"
      assert encoded!(true) == "true"
      assert encoded!(false) == "false"
      assert encoded!(42) == "42"
      assert encoded!(-7) == "-7"
      assert encoded!("hi") == ~s("hi")
    end

    test "strings escape quote, backslash, and C0 controls as " do
      assert encoded!(~s(a"b\\c)) == ~s("a\\"b\\\\c")
      assert encoded!("a\nbc") == ~s("a\\u000ab\\u0001c")
    end

    test "non-ASCII passes through as raw UTF-8" do
      assert encoded!("粽子") == ~s("粽子")
    end

    test "lists and nested maps" do
      assert encoded!(%{"a" => [1, "x"], "b" => nil}) == ~s({"a":[1,"x"],"b":null})
    end

    test "map keys sort by raw UTF-8 bytes" do
      assert encoded!(%{"b" => 1, "a" => 2, "粽" => 3}) == ~s({"a":2,"b":1,"粽":3})
    end

    test "atom keys encode as their name" do
      assert encoded!(%{onset: 1}) == ~s({"onset":1})
    end
  end

  describe "rejection (adapter obligation)" do
    test "floats" do
      assert {:error, {:non_canonical, 1.5}} = Digest.encode(1.5)
    end

    test "tuples" do
      assert {:error, {:non_canonical, {1, 2}}} = Digest.encode({1, 2})
    end

    test "structs" do
      assert {:error, {:non_canonical, %URI{}}} = Digest.encode(%URI{})
    end

    test "non-binary, non-atom map keys" do
      assert {:error, {:non_canonical_key, 1}} = Digest.encode(%{1 => :a})
    end

    test "invalid UTF-8 strings and keys are not canonical strings" do
      assert {:error, {:non_canonical, <<0xFF>>}} = Digest.encode(<<0xFF>>)
      assert {:error, {:non_canonical, <<0xE4, 0xB8>>}} = Digest.encode(<<0xE4, 0xB8>>)
      assert {:error, {:non_canonical_key, <<0xFF>>}} = Digest.encode(%{<<0xFF>> => 1})
    end

    test "atom/binary key collisions after conversion" do
      assert {:error, :duplicate_keys} = Digest.encode(%{"a" => 2, a: 1})
    end

    test "nested rejection propagates" do
      assert {:error, {:non_canonical, 1.5}} = Digest.encode(%{"ok" => [1, %{"bad" => 1.5}]})
    end
  end

  describe "digest" do
    test "is lowercase hex sha256 of the canonical encoding" do
      {:ok, d} = Digest.digest(%{"a" => 1})

      assert d == Base.encode16(:crypto.hash(:sha256, ~s({"a":1})), case: :lower)
    end
  end
end
