defmodule Tamale.Op do
  @moduledoc """
  Edit operations — the kernel's first-class edit intent.

  Every write to a `Tamale.Space` is expressed as one of these ops and
  appended to the space's log. Anchors are transported along the log;
  nothing is re-inferred from state diffs.

  ## Identity conventions (kernel-level, not policy)

  - `Split` — the **first child inherits the parent's id**
    (`children` must be `[parent_id | new_ids]`). Point anchors on the
    parent survive on the first child; whole-span semantics belong to
    `Tamale.Anchor.Metric` + warps.
  - `Merge` — `into` must be `hd(ids)`; the remaining ids die.
  - `Delete` — terminal for anchors referencing the id. Relocation is
    policy, not transport.
  - `Retime` — carries before/after spans so warp construction (adapter
    layer) has its inputs. Structure and identity are unaffected, but
    note-timing edits MUST go through this op: an op log with holes where
    timing changed silently is worse than no log.

  When edits arrive as two raw states instead of ops (file import, reload,
  collaboration), they must be lowered into ops by a `diff(old, new)`
  fallback adapter — heuristics live in that one function, never in the
  kernel's decision paths.
  """

  defmodule Insert do
    @moduledoc "Insert `id` after `after_id` (`:head` inserts at the front)."
    defstruct [:id, :after_id]
    @type t :: %__MODULE__{id: Tamale.id(), after_id: Tamale.id() | :head}
  end

  defmodule Delete do
    @moduledoc "Delete `id`. Terminal for anchors referencing it."
    defstruct [:id]
    @type t :: %__MODULE__{id: Tamale.id()}
  end

  defmodule Split do
    @moduledoc "Split `id` into `children`; `hd(children)` must equal `id`."
    defstruct [:id, :children]
    @type t :: %__MODULE__{id: Tamale.id(), children: [Tamale.id(), ...]}
  end

  defmodule Merge do
    @moduledoc "Merge adjacent `ids` into `into`, which must be `hd(ids)`."
    defstruct [:ids, :into]
    @type t :: %__MODULE__{ids: [Tamale.id(), ...], into: Tamale.id()}
  end

  defmodule Move do
    @moduledoc "Move `id` to right after `after_id` (`:head` = front)."
    defstruct [:id, :after_id]
    @type t :: %__MODULE__{id: Tamale.id(), after_id: Tamale.id() | :head}
  end

  defmodule Retime do
    @moduledoc """
    Re-time `id` from `old_span` to `new_span` (`{start, stop}` in the
    space's native coordinate). Identity and order are untouched; the spans
    exist so the adapter layer can build warps for `Anchor.Metric`.

    Spans are coordinates (`Tamale.Coord`): integers and `{num, den}`
    rationals are accepted, floats are rejected with `:invalid_span` at
    `Tamale.Space.apply_batch/2`.
    """
    defstruct [:id, :old_span, :new_span]

    @type t :: %__MODULE__{
            id: Tamale.id(),
            old_span: {Tamale.Coord.input(), Tamale.Coord.input()},
            new_span: {Tamale.Coord.input(), Tamale.Coord.input()}
          }
  end

  @type t :: Insert.t() | Delete.t() | Split.t() | Merge.t() | Move.t() | Retime.t()
end
