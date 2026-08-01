defmodule Tamale.Digest do
  @moduledoc """
  Canonical digests — the portable replacement for BEAM-specific
  `term_to_binary` hashing. Spec: `docs/spec/canonical-digest.md`.

  A **canonical term** is `nil`, a boolean, an integer, a UTF-8 binary, a
  list of canonical terms, or a map with binary or atom keys whose values
  are canonical terms. Anything else — floats, tuples, structs — is
  rejected: adapting domain values into canonical form is the channel
  adapter's job (normalization per `docs/decisions/0005` — Decimal
  strings, frame indices, ...), not the kernel's. Rejecting floats at
  this boundary is what keeps that adapter obligation honest.

  The digest is the lowercase hex of `sha256(canonical_encoding(term))`,
  so any language can reproduce it — that is what lets `Tamale.Patch`
  join the conformance vectors.
  """

  @typedoc "A term the kernel can digest without adapter help."
  @type canonical ::
          nil
          | boolean()
          | integer()
          | binary()
          | [canonical]
          | %{optional(binary() | atom()) => canonical()}

  @doc "Lowercase hex of `sha256(canonical_encoding(term))`."
  @spec digest(term()) :: {:ok, String.t()} | {:error, term()}
  def digest(term) do
    with {:ok, iodata} <- encode(term) do
      {:ok, :sha256 |> :crypto.hash(iodata) |> Base.encode16(case: :lower)}
    end
  end

  @doc """
  The canonical byte encoding of a term (exposed so the spec and the
  conformance vectors can pin the encoding itself, not just the digest).
  """
  @spec encode(term()) :: {:ok, iodata()} | {:error, term()}
  def encode(term), do: do_encode(term)

  defp do_encode(nil), do: {:ok, ~c"null"}
  defp do_encode(true), do: {:ok, ~c"true"}
  defp do_encode(false), do: {:ok, ~c"false"}
  defp do_encode(i) when is_integer(i), do: {:ok, Integer.to_string(i)}

  # A canonical string is valid UTF-8 — other languages (Rust String, TS
  # JSON) cannot even represent an invalid byte string, so it is rejected
  # like any non-canonical value.
  defp do_encode(b) when is_binary(b) do
    if String.valid?(b) do
      {:ok, [?", escape(b), ?"]}
    else
      {:error, {:non_canonical, b}}
    end
  end

  defp do_encode(list) when is_list(list) do
    with {:ok, parts} <- map_ok(list, &do_encode/1) do
      {:ok, [?[, Enum.intersperse(parts, ?,), ?]]}
    end
  end

  defp do_encode(map) when is_map(map) do
    if is_struct(map) do
      {:error, {:non_canonical, map}}
    else
      with {:ok, named} <- map_ok(Map.to_list(map), &name_key/1),
           :ok <- unique_keys(named),
           {:ok, pairs} <- map_ok(Enum.sort(named), &encode_pair/1) do
        {:ok, [?{, Enum.intersperse(pairs, ?,), ?}]}
      end
    end
  end

  defp do_encode(other), do: {:error, {:non_canonical, other}}

  # Atom keys are an Elixir-side convenience, encoded as their name;
  # vectors and other languages use binary keys only. Keys are strings,
  # so the same UTF-8 validity rule applies to them.
  defp name_key({key, value}) when is_atom(key), do: {:ok, {Atom.to_string(key), value}}

  defp name_key({key, value}) when is_binary(key) do
    if String.valid?(key) do
      {:ok, {key, value}}
    else
      {:error, {:non_canonical_key, key}}
    end
  end

  defp name_key({key, _value}), do: {:error, {:non_canonical_key, key}}

  defp unique_keys(named) do
    keys = Enum.map(named, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :duplicate_keys}
    end
  end

  defp encode_pair({name, value}) do
    with {:ok, encoded} <- do_encode(value) do
      {:ok, [?", escape(name), ?", ?:, encoded]}
    end
  end

  # JSON string escaping: `"`, `\`, and every C0 control byte as ;
  # all other bytes pass through as raw UTF-8.
  defp escape(binary), do: for(<<c <- binary>>, do: escape_byte(c))

  defp escape_byte(?"), do: "\\\""
  defp escape_byte(?\\), do: "\\\\"
  defp escape_byte(c) when c < 0x20, do: :io_lib.format("\\u~4.16.0b", [c])
  defp escape_byte(c), do: c

  defp map_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end
end
