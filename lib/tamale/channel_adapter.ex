defmodule Tamale.ChannelAdapter do
  @moduledoc """
  The single kernel-mandated channel-adapter callback.

  Transport moves anchor *intervals*; payloads must be transformed under
  the same warp, and that transformation is channel-specific:

  - control-point curves are exact under uniform translate/scale;
    split-induced piecewise warps require cutting the payload at piece
    boundaries (Bezier splitting at cut points is adapter-specific logic)
  - dense frames are resampled generically; the interpolator is policy,
    not kernel

  Obtain the warp for a `Tamale.Anchor.Metric` transport from
  `Tamale.Transport.fold_warp/4`, called with the same arguments as the
  transport itself — it returns exactly the warp the transport folded.

  This callback is the deliberate residue of zongzi's `on_rebase/4` — an
  order of magnitude smaller, but it does not go to zero.
  """

  @doc """
  Transforms `payload` under `warp`.

  Returns `{:ok, payload'}` when the payload survives the coordinate
  change, `{:conflict, reason}` when the channel considers the transform
  lossy enough to void the edit (e.g. a hand-tuned value whose support
  was clipped).
  """
  @callback warp_payload(payload :: term(), warp :: Tamale.Warp.t()) ::
              {:ok, term()} | {:conflict, term()}
end
