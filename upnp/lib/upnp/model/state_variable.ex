defmodule UPnP.StateVariable do
  @moduledoc "A state variable declared in an SCPD service state table."

  defstruct name: nil,
            data_type: nil,
            default_value: nil,
            sends_events: true,
            allowed_values: [],
            allowed_range: nil

  @type t :: %__MODULE__{
          name: binary() | nil,
          data_type: binary() | nil,
          default_value: binary() | nil,
          sends_events: boolean(),
          allowed_values: [binary()],
          allowed_range: UPnP.AllowedValueRange.t() | nil
        }
end
