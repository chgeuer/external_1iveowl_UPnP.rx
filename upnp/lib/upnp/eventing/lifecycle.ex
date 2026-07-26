defmodule UPnP.Eventing.Lifecycle do
  @moduledoc """
  An immutable event describing a GENA subscription lifecycle transition.

  Protocol and network failures are delivered as lifecycle data rather than
  crashing the subscription process.
  """

  @enforce_keys [:kind, :occurred_at]
  defstruct kind: nil,
            sid: nil,
            timeout: nil,
            reason: nil,
            expected_sequence: nil,
            actual_sequence: nil,
            attempt: nil,
            occurred_at: nil

  @type kind ::
          :subscribed
          | :renewed
          | :lost
          | :resubscribing
          | :resubscribed
          | :resubscribe_failed
          | :retry_exhausted
          | :sequence_gap
          | :duplicate
          | :stale
          | :subscription_refused

  @type t :: %__MODULE__{
          kind: kind(),
          sid: String.t() | nil,
          timeout: pos_integer() | :infinite | nil,
          reason: term(),
          expected_sequence: non_neg_integer() | nil,
          actual_sequence: non_neg_integer() | nil,
          attempt: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }
end
