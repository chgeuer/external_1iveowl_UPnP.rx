defmodule UPnP.SCPD do
  @moduledoc "An immutable Service Control Protocol Description."

  defstruct spec_version: nil, actions: [], state_variables: []

  @type t :: %__MODULE__{
          spec_version: UPnP.SpecVersion.t() | nil,
          actions: [UPnP.ActionDescription.t()],
          state_variables: [UPnP.StateVariable.t()]
        }
end
