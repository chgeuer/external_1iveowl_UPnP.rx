defmodule UPnP.EventedProperty do
  @moduledoc "One variable value decoded from a GENA property set."

  defstruct name: nil, value: nil

  @type t :: %__MODULE__{
          name: binary() | nil,
          value: binary() | nil
        }
end
