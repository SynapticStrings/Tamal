defmodule Tamale.PatchTest do
  use ExUnit.Case, async: true

  alias Tamale.Patch

  test "payload applies when the base is unchanged" do
    {:ok, p} = Patch.new(%{f0: ["110.0", "220.0"]}, :user_delta)
    assert {:ok, :user_delta} = Patch.resolve(p, %{f0: ["110.0", "220.0"]})
  end

  test "any base change conflicts — no tolerance" do
    {:ok, p} = Patch.new(%{f0: ["110.0", "220.0"]}, :user_delta)
    assert {:conflict, :base_changed} = Patch.resolve(p, %{f0: ["110.0", "220.0000001"]})
  end

  test "key order is irrelevant (canonical encoding sorts keys)" do
    {:ok, p} = Patch.new(%{a: 1, b: 2}, :payload)
    assert {:ok, :payload} = Patch.resolve(p, %{b: 2, a: 1})
  end

  test "a float base is rejected at mount — the adapter must normalize first" do
    assert {:error, {:non_canonical, 1.0}} = Patch.new(%{f0: [1.0, 2.0]}, :delta)
  end

  test "a float fresh base is rejected at resolve, not silently conflicted" do
    {:ok, p} = Patch.new(%{f0: [110, 220]}, :delta)
    assert {:error, {:non_canonical, 1.0}} = Patch.resolve(p, %{f0: [1.0, 2.0]})
  end
end
