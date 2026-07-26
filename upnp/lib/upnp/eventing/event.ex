defmodule UPnP.Eventing.Event do
  @moduledoc """
  One accepted GENA `NOTIFY` property-set.

  `properties` contains only values carried by this notification. `snapshot`
  contains the subscription's immutable last-known value for every property
  after applying the notification.
  """

  @enforce_keys [:sid, :sequence, :properties, :snapshot, :initial?, :received_at]
  defstruct [:sid, :sequence, :properties, :snapshot, :initial?, :received_at]

  @type t :: %__MODULE__{
          sid: String.t(),
          sequence: non_neg_integer(),
          properties: [UPnP.EventedProperty.t()],
          snapshot: [UPnP.EventedProperty.t()],
          initial?: boolean(),
          received_at: DateTime.t()
        }
end
