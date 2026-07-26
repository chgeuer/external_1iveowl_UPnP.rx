defmodule UPnP.ArgumentDescription do
  @moduledoc "An input or output argument declared by an SCPD action."

  @type direction :: :in | :out | :unknown

  defstruct name: nil,
            direction: :unknown,
            is_return_value: false,
            related_state_variable: nil

  @type t :: %__MODULE__{
          name: binary() | nil,
          direction: direction(),
          is_return_value: boolean(),
          related_state_variable: binary() | nil
        }
end
