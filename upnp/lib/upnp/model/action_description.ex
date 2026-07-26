defmodule UPnP.ActionDescription do
  @moduledoc "An action declared by a service SCPD."

  defstruct name: nil, arguments: []

  @type t :: %__MODULE__{
          name: binary() | nil,
          arguments: [UPnP.ArgumentDescription.t()]
        }
end
