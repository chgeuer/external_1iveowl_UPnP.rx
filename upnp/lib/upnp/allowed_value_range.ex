defmodule UPnP.AllowedValueRange do
  @moduledoc "An optional numeric range declared for an SCPD state variable."

  defstruct minimum: nil, maximum: nil, step: nil

  @type t :: %__MODULE__{
          minimum: binary() | nil,
          maximum: binary() | nil,
          step: binary() | nil
        }
end
