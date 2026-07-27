defmodule UPnP.Subscription.Closed do
  @moduledoc """
  A typed terminal event for a control-point-owned local subscription.

  Roster and announcement subscriptions are generation-bound. After
  `:internal_restart`, callers must subscribe again to receive a fresh atomic
  snapshot before live events resume.
  """

  @enforce_keys [:reason, :occurred_at]
  defstruct [:reason, :occurred_at]

  @type reason :: :graceful_close | :internal_restart | :terminal_stop
  @type t :: %__MODULE__{reason: reason(), occurred_at: DateTime.t()}
end
