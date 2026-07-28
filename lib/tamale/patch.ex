defmodule Tamale.Patch do
  @moduledoc """
  Semantic survival: a user edit is `(base_digest, payload)`.

  After upstream regeneration:

      digest(new_base) == base_digest  →  {:ok, payload}
      otherwise                        →  {:conflict, :base_changed}

  The hard rules, inherited from zongzi's snapshot/resolve doctrine:

  - **No tolerance.** A tolerance knob is a fuzzy-match backdoor.
  - The death criterion is *whether the base itself is still there*, not
    whether the inputs that produced the base changed.

  Digests are computed Caller-side over deterministic projection slices —
  the protocol requirement on engines is "projection is deterministic and
  slice-addressable", not "engines emit digests".

  Chunked digests (per-element chunks, so a local regeneration conflicts
  locally instead of globally) are a policy concern built on top of this
  type; they change granularity, not semantics.
  """

  @type t :: %__MODULE__{base_digest: binary(), payload: term()}

  defstruct [:base_digest, :payload]

  @doc "Deterministic digest of a base (projection slice)."
  @spec digest(term()) :: binary()
  def digest(base), do: :crypto.hash(:sha256, :erlang.term_to_binary(base))

  @doc "Captures a patch against `base`."
  @spec new(term(), term()) :: t()
  def new(base, payload), do: %__MODULE__{base_digest: digest(base), payload: payload}

  @doc "Judges whether the payload still applies to `fresh_base`."
  @spec resolve(t(), term()) :: {:ok, term()} | {:conflict, :base_changed}
  def resolve(%__MODULE__{base_digest: d, payload: payload}, fresh_base) do
    if digest(fresh_base) == d, do: {:ok, payload}, else: {:conflict, :base_changed}
  end
end
