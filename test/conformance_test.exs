defmodule Tamale.ConformanceRunner do
  @moduledoc false
  # Executes one JSON conformance scenario against the kernel.
  # Format spec: test/conformance/README.md

  import ExUnit.Assertions

  alias Tamale.{Digest, Patch, Space, Transport, Warp}

  @doc false
  # OTP `:json.decode` maps JSON null to the atom `:null`; vectors mean `nil`.
  def deep_from_json(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, deep_from_json(v)} end)

  def deep_from_json(list) when is_list(list), do: Enum.map(list, &deep_from_json/1)
  def deep_from_json(:null), do: nil
  def deep_from_json(term), do: term
  alias Tamale.Anchor.{Metric, Ordinal, Relative}
  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}

  def run(scenario) do
    {:ok, space} = scenario |> Map.get("space", []) |> Space.new()
    space = apply_script(space, Map.get(scenario, "script", []), scenario)
    space = maybe_truncate(space, scenario)

    if expected = Map.get(scenario, "expect_version") do
      assert space.version == expected,
             "expected head version #{expected}, got #{space.version}"
    end

    provider = warp_provider(Map.get(scenario, "warps", []))

    for kase <- Map.get(scenario, "cases", []) do
      anchor = decode_anchor(Map.fetch!(kase, "anchor"))

      actual = anchor |> dispatch(space, provider) |> encode_result()
      expected = kase |> Map.fetch!("expect") |> normalize_expected()

      assert_json_eq(actual, expected, kase, "anchor:   #{inspect(anchor)}")
    end

    for kase <- Map.get(scenario, "digest_cases", []) do
      base = Map.fetch!(kase, "base")

      actual =
        case Digest.digest(base) do
          {:ok, digest} -> %{"status" => "ok", "digest" => digest}
          {:error, reason} -> %{"status" => "error", "reason" => encode_term(reason)}
        end

      assert_json_eq(actual, Map.fetch!(kase, "expect"), kase, "base:     #{inspect(base)}")
    end

    for kase <- Map.get(scenario, "patch_cases", []) do
      base = Map.fetch!(kase, "base")
      fresh_base = Map.fetch!(kase, "fresh_base")

      actual =
        with {:ok, patch} <- Patch.new(base, Map.get(kase, "payload")) do
          Patch.resolve(patch, fresh_base)
        end
        |> encode_patch_result()

      assert_json_eq(
        actual,
        Map.fetch!(kase, "expect"),
        kase,
        "base:     #{inspect(base)}\n  fresh:    #{inspect(fresh_base)}"
      )
    end
  end

  defp encode_patch_result({:ok, payload}), do: %{"status" => "ok", "payload" => payload}

  defp encode_patch_result({:conflict, reason}),
    do: %{"status" => "conflict", "reason" => encode_term(reason)}

  defp encode_patch_result({:error, reason}),
    do: %{"status" => "error", "reason" => encode_term(reason)}

  defp assert_json_eq(actual, expected, kase, context) do
    unless json_eq?(actual, expected) do
      flunk("""
      conformance case failed#{case_label(kase)}
        #{context}
        expected: #{inspect(expected, limit: :infinity)}
        actual:   #{inspect(actual, limit: :infinity)}
      """)
    end
  end

  # ---- script ----

  defp apply_script(space, batches, scenario) do
    Enum.reduce_while(batches, {space, nil}, fn batch, {sp, _} ->
      ops = Enum.map(batch, &decode_op/1)

      case Space.apply_batch(sp, ops) do
        {:ok, sp2} -> {:cont, {sp2, nil}}
        {:error, reason} -> {:halt, {sp, reason}}
      end
    end)
    |> check_script_outcome(scenario)
  end

  defp check_script_outcome({space, nil}, scenario) do
    if Map.has_key?(scenario, "expect_space_error") do
      flunk(
        "expected space error #{inspect(scenario["expect_space_error"])} but the script applied cleanly"
      )
    end

    space
  end

  defp check_script_outcome({space, reason}, scenario) do
    actual = encode_term(reason)

    case Map.get(scenario, "expect_space_error") do
      nil ->
        flunk("script failed unexpectedly: #{inspect(actual)}")

      expected ->
        unless json_eq?(actual, expected) do
          flunk("expected space error #{inspect(expected)}, got #{inspect(actual)}")
        end

        space
    end
  end

  defp maybe_truncate(space, scenario) do
    case Map.get(scenario, "truncate") do
      nil -> space
      v -> Space.truncate(space, v)
    end
  end

  defp decode_op(%{"op" => "insert", "id" => id, "after_id" => after_id}),
    do: %Insert{id: id, after_id: decode_after(after_id)}

  defp decode_op(%{"op" => "delete", "id" => id}), do: %Delete{id: id}

  defp decode_op(%{"op" => "split", "id" => id, "children" => children}),
    do: %Split{id: id, children: children}

  defp decode_op(%{"op" => "merge", "ids" => ids, "into" => into}),
    do: %Merge{ids: ids, into: into}

  defp decode_op(%{"op" => "move", "id" => id, "after_id" => after_id}),
    do: %Move{id: id, after_id: decode_after(after_id)}

  defp decode_op(%{"op" => "retime", "id" => id, "old_span" => [s, e], "new_span" => [s2, e2]}),
    do: %Retime{id: id, old_span: {s, e}, new_span: {s2, e2}}

  defp decode_op(other), do: raise("undecodable op in vector: #{inspect(other)}")

  defp decode_after("head"), do: :head
  defp decode_after(id), do: id

  # ---- anchors ----

  defp decode_anchor(%{"type" => "ordinal"} = a) do
    %Ordinal{
      refs: Map.fetch!(a, "refs"),
      adjacent?: Map.get(a, "adjacent", false),
      at_version: Map.get(a, "at_version", 0)
    }
  end

  defp decode_anchor(%{"type" => "metric"} = a) do
    %Metric{
      coord: Map.fetch!(a, "coord"),
      from: Map.fetch!(a, "from"),
      to: Map.fetch!(a, "to"),
      at_version: Map.get(a, "at_version", 0)
    }
  end

  defp decode_anchor(%{"type" => "relative"} = a) do
    %Relative{
      ref: Map.fetch!(a, "ref"),
      from_offset: Map.fetch!(a, "from_offset"),
      to_offset: Map.fetch!(a, "to_offset"),
      at_version: Map.get(a, "at_version", 0)
    }
  end

  defp decode_anchor(other), do: raise("undecodable anchor in vector: #{inspect(other)}")

  defp dispatch(%Metric{} = anchor, space, provider),
    do: Transport.transport(anchor, space, provider)

  defp dispatch(anchor, space, _provider), do: Transport.transport(anchor, space)

  # ---- warps ----

  defp warp_provider(warps) do
    table =
      Map.new(warps, fn w ->
        {{Map.fetch!(w, "coord"), Map.fetch!(w, "entry")}, Map.fetch!(w, "segments")}
      end)

    fn coord, {version, _ops} ->
      case Map.get(table, {coord, version}) do
        nil ->
          Warp.identity()

        segments ->
          segs =
            Enum.map(segments, fn %{"old" => [o0, o1], "new" => [n0, n1]} ->
              {{o0, o1}, {n0, n1}}
            end)

          case Warp.from_segments(segs) do
            {:ok, warp} ->
              warp

            {:error, reason} ->
              raise "invalid warp in vector (coord #{inspect(coord)}, entry #{version}): #{inspect(reason)}"
          end
      end
    end
  end

  # ---- result encoding (kernel terms -> JSON-shaped terms) ----

  defp encode_result({:ok, anchor}), do: %{"status" => "ok", "anchor" => encode_anchor(anchor)}

  defp encode_result({:clip, covered, lost}) do
    %{
      "status" => "clip",
      "covered" => Enum.map(covered, &encode_anchor/1),
      "lost" => Enum.map(lost, fn {f, t} -> [f, t] end)
    }
  end

  defp encode_result({:ambiguous, candidates}),
    do: %{"status" => "ambiguous", "candidates" => Enum.map(candidates, &encode_anchor/1)}

  defp encode_result({:undefined, reason}),
    do: %{"status" => "undefined", "reason" => encode_term(reason)}

  defp encode_result({:error, reason}),
    do: %{"status" => "error", "reason" => encode_term(reason)}

  defp encode_anchor(%Ordinal{} = a),
    do: %{
      "type" => "ordinal",
      "refs" => a.refs,
      "adjacent" => a.adjacent?,
      "at_version" => a.at_version
    }

  defp encode_anchor(%Metric{} = a),
    do: %{
      "type" => "metric",
      "coord" => a.coord,
      "from" => a.from,
      "to" => a.to,
      "at_version" => a.at_version
    }

  defp encode_anchor(%Relative{} = a),
    do: %{
      "type" => "relative",
      "ref" => a.ref,
      "from_offset" => a.from_offset,
      "to_offset" => a.to_offset,
      "at_version" => a.at_version
    }

  defp encode_term(term) when is_atom(term), do: Atom.to_string(term)

  defp encode_term(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&encode_term/1)

  defp encode_term(term) when is_list(term), do: Enum.map(term, &encode_term/1)
  defp encode_term(term), do: term

  # Expected anchors go through the same decode/encode round-trip so
  # defaulted fields (adjacent, at_version) line up with actual results.
  defp normalize_expected(%{"status" => "ok", "anchor" => a}),
    do: %{"status" => "ok", "anchor" => a |> decode_anchor() |> encode_anchor()}

  defp normalize_expected(%{"status" => "clip", "covered" => covered, "lost" => lost}),
    do: %{
      "status" => "clip",
      "covered" => Enum.map(covered, &(&1 |> decode_anchor() |> encode_anchor())),
      "lost" => lost
    }

  defp normalize_expected(other), do: other

  # ---- comparison ----

  # JSON has one number type; vectors must not distinguish 2 from 2.0.
  # Prefer binary-exact values (integers, halves, quarters) anyway.
  defp json_eq?(a, b) when is_number(a) and is_number(b), do: a == b

  defp json_eq?(a, b) when is_map(a) and is_map(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and json_eq?(v, Map.fetch!(b, k)) end)
  end

  defp json_eq?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and a |> Enum.zip_with(b, &json_eq?/2) |> Enum.all?()
  end

  defp json_eq?(a, b), do: a == b

  defp case_label(kase) do
    case Map.get(kase, "name") do
      nil -> ""
      name -> ": #{name}"
    end
  end
end

defmodule Tamale.ConformanceTest do
  use ExUnit.Case, async: false

  @files Path.wildcard(Path.join(__DIR__, "conformance/*.json"))

  for file <- @files do
    @external_resource file
    %{"scenarios" => scenarios} =
      file |> File.read!() |> :json.decode() |> Tamale.ConformanceRunner.deep_from_json()

    family = Path.basename(file, ".json")

    for scenario <- scenarios do
      test "#{family}/#{Map.fetch!(scenario, "name")}" do
        Tamale.ConformanceRunner.run(unquote(Macro.escape(scenario)))
      end
    end
  end
end
