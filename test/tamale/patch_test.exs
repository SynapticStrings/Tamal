defmodule Tamale.PatchTest do
  use ExUnit.Case, async: true

  alias Tamale.Patch

  test "payload applies when the base is unchanged" do
    p = Patch.new(%{f0: [1.0, 2.0]}, :user_delta)
    assert {:ok, :user_delta} = Patch.resolve(p, %{f0: [1.0, 2.0]})
  end

  test "any base change conflicts — no tolerance" do
    p = Patch.new(%{f0: [1.0, 2.0]}, :user_delta)
    assert {:conflict, :base_changed} = Patch.resolve(p, %{f0: [1.0, 2.0000001]})
  end
end
