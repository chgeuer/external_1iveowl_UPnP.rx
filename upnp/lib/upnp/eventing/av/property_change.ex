defmodule UPnP.Eventing.AV.PropertyChange do
  @moduledoc "A variable change decoded from an AV LastChange payload."

  defstruct instance_id: 0, name: nil, value: nil, channel: nil

  @type t :: %__MODULE__{
          instance_id: non_neg_integer(),
          name: binary() | nil,
          value: binary() | nil,
          channel: binary() | nil
        }
end
