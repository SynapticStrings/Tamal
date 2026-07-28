defmodule Tamale.Patch do
  @moduledoc """
  Semantic survival: a user edit is `(base_digest, payload)`.

  After upstream regeneration:

      digest(new_base) == base_digest  →  {:ok, payload}
      otherwise                        →  {:conflict, :base_changed}

  The hard rules, inherited from zongzi's snapshot/resolve doctrine:

  - **No tolerance.** A tolerance knob is a fuzzy-match backdoor. (The
    legitimate form of "fuzziness" is declared normalization *before* the
    digest — `docs/decisions/0005`.)
  - The death criterion is *whether the base itself is still there*, not
    whether the inputs that produced the base changed.

  Digests are canonical (`Tamale.Digest`, spec:
  `docs/spec/canonical-digest.md`): the base must be reduced to a
  canonical term — nil/booleans/integers/binaries/lists/plain maps — by
  the time it reaches this module. Floats, tuples, and structs are
  rejected, because adapting domain values (seconds → Decimal strings,
  timestamps → frame indices, projection structs → plain maps) is the
  channel adapter's job, not the kernel's. Digests are computed
  Caller-side over deterministic projection slices — the protocol
  requirement on engines is "projection is deterministic and
  slice-addressable", not "engines emit digests".

  Chunked digests (per-element chunks, so a local regeneration conflicts
  locally instead of globally) are a policy concern built on top of this
  type (`docs/decisions/0006`); they change granularity, not semantics.
  """

  alias Tamale.Digest

  @type t :: %__MODULE__{base_digest: String.t(), payload: term()}

  defstruct [:base_digest, :payload]

  @doc """
  Captures a patch against `base`.

  `base` must be a canonical term (see `Tamale.Digest`); otherwise
  `{:error, reason}` — typically a float or struct the channel adapter
  failed to normalize.
  """
  @spec new(term(), term()) :: {:ok, t()} | {:error, term()}
  def new(base, payload) do
    with {:ok, digest} <- Digest.digest(base) do
      {:ok, %__MODULE__{base_digest: digest, payload: payload}}
    end
  end

  @doc """
  Judges whether the payload still applies to `fresh_base`.

  `{:error, reason}` when `fresh_base` is not canonical — same adapter
  obligation as at mount time.
  """
  @spec resolve(t(), term()) :: {:ok, term()} | {:conflict, :base_changed} | {:error, term()}
  def resolve(%__MODULE__{base_digest: digest, payload: payload}, fresh_base) do
    with {:ok, fresh} <- Digest.digest(fresh_base) do
      if fresh == digest, do: {:ok, payload}, else: {:conflict, :base_changed}
    end
  end
end
