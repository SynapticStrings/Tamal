defmodule Tamale.Coord do
  @moduledoc """
  Exact rational coordinates — the kernel's only number.

  Coordinates appear wherever an anchor references a position rather than
  an identity: `Anchor.Metric` intervals, `Anchor.Relative` offsets,
  `Op.Retime` spans, and every `Tamale.Warp` endpoint. The kernel
  interpolates and composes those values (`Warp.at/2`, `Warp.compose/2`),
  so the coordinate type must be **closed under scaling by rationals** —
  a requirement integers and floats both fail: integers cannot represent
  frame 3 stretched by 4/3, and floats smear it into rounding dust that
  no conformance vector can pin.

  The kernel's answer is the rational pair `{num, den}`, normalized so
  that `den > 0` and `gcd(|num|, den) == 1`. Normalization makes the
  representation canonical: two equal coordinates are always `==`-equal
  structs of the same shape, so plain term equality is exact equality.

  ## Boundary rules

  - Integers are accepted everywhere and promoted to `{n, 1}`.
  - Floats are rejected. `cast/1` reports them as
    `{:error, {:invalid_coordinate, value}}`; `cast!/1` raises. This is
    the same doctrine as the canonical digest (`docs/decisions/0005`):
    normalizing domain floats into exact values — seconds as
    microseconds, frames as integers — is the channel adapter's job,
    with a declared resolution.
  - Kernel outputs are always normalized rationals.

  ## Wire form

  In conformance vectors and any JSON interchange a coordinate is:

  - a JSON integer when `den == 1` — `4` means `{4, 1}`
  - a `"num/den"` string otherwise — `"4/3"` means `{4, 3}`

  Floats are not representable on the wire; `decode/1` rejects them.
  """

  import Kernel, except: [max: 2, min: 2]

  @typedoc """
  A normalized rational: `{num, den}` with `den > 0` and the fraction
  fully reduced.
  """
  @type t :: {integer(), pos_integer()}

  @typedoc "Anything `cast/1` accepts: a rational or a bare integer."
  @type input :: t() | integer()

  @doc "Promotes an integer to a coordinate."
  @spec new(integer()) :: t()
  def new(n) when is_integer(n), do: {n, 1}

  @doc """
  Builds a normalized coordinate. Raises `ArgumentError` on a zero
  denominator or non-integer parts — a caller bug, not data.
  """
  @spec new(integer(), integer()) :: t()
  def new(num, den) when is_integer(num) and is_integer(den) do
    cond do
      den == 0 -> raise ArgumentError, "rational coordinate with zero denominator"
      den < 0 -> new(-num, -den)
      true -> reduce(num, den)
    end
  end

  @doc """
  Casts external data to a coordinate. Accepts integers and `{num, den}`
  pairs; anything else — floats included — is
  `{:error, {:invalid_coordinate, value}}`.
  """
  @spec cast(term()) :: {:ok, t()} | {:error, {:invalid_coordinate, term()}}
  def cast(n) when is_integer(n), do: {:ok, {n, 1}}

  def cast({num, den} = pair) when is_integer(num) and is_integer(den) do
    if den == 0, do: {:error, {:invalid_coordinate, pair}}, else: {:ok, new(num, den)}
  end

  def cast(other), do: {:error, {:invalid_coordinate, other}}

  @doc "Raising variant of `cast/1`, for hand-written coordinates."
  @spec cast!(term()) :: t()
  def cast!(term) do
    case cast(term) do
      {:ok, coord} ->
        coord

      {:error, {:invalid_coordinate, value}} ->
        raise ArgumentError, "invalid coordinate: #{inspect(value)}"
    end
  end

  @doc "Encodes a coordinate to its wire form: integer, or `\"num/den\"`."
  @spec encode(t()) :: integer() | String.t()
  def encode({num, 1}), do: num
  def encode({num, den}), do: "#{num}/#{den}"

  @doc """
  Decodes the wire form. Floats and malformed strings are
  `{:error, {:invalid_coordinate, value}}`.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, {:invalid_coordinate, term()}}
  def decode(n) when is_integer(n), do: {:ok, {n, 1}}

  def decode(str) when is_binary(str) do
    case String.split(str, "/") do
      [num, den] ->
        with {num, ""} <- Integer.parse(num),
             {den, ""} <- Integer.parse(den),
             {:ok, coord} <- cast({num, den}) do
          {:ok, coord}
        else
          _ -> {:error, {:invalid_coordinate, str}}
        end

      _ ->
        {:error, {:invalid_coordinate, str}}
    end
  end

  def decode(other), do: {:error, {:invalid_coordinate, other}}

  @doc false
  defp reduce(num, den) do
    g = Integer.gcd(num, den)
    {div(num, g), div(den, g)}
  end

  # ---- arithmetic ----

  @spec add(t(), t()) :: t()
  def add({a, b}, {c, d}), do: reduce(a * d + c * b, b * d)

  @spec negate(t()) :: t()
  def negate({a, b}), do: {-a, b}

  @spec sub(t(), t()) :: t()
  def sub(a, b), do: add(a, negate(b))

  @spec mul(t(), t()) :: t()
  def mul({a, b}, {c, d}), do: reduce(a * c, b * d)

  @doc "Divides `a` by `b`. Raises `ArgumentError` when `b` is zero."
  @spec divide(t(), t()) :: t()
  def divide(_a, {0, _}), do: raise(ArgumentError, "division by a zero coordinate")
  def divide({a, b}, {c, d}), do: new(a * d, b * c)

  # ---- ordering ----

  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare({a, b}, {c, d}) do
    cond do
      a * d < c * b -> :lt
      a * d > c * b -> :gt
      true -> :eq
    end
  end

  @spec lt?(t(), t()) :: boolean()
  def lt?(a, b), do: compare(a, b) == :lt

  @spec lte?(t(), t()) :: boolean()
  def lte?(a, b), do: compare(a, b) != :gt

  @spec gt?(t(), t()) :: boolean()
  def gt?(a, b), do: compare(a, b) == :gt

  @spec gte?(t(), t()) :: boolean()
  def gte?(a, b), do: compare(a, b) != :lt

  @spec max(t(), t()) :: t()
  def max(a, b), do: if(lt?(a, b), do: b, else: a)

  @spec min(t(), t()) :: t()
  def min(a, b), do: if(gt?(a, b), do: b, else: a)
end
