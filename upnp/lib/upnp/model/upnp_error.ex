defmodule UPnP.UpnpError do
  @moduledoc "A protocol error carried by a SOAP UPnPError fault."

  defstruct code: nil, description: nil

  @type t :: %__MODULE__{
          code: integer() | nil,
          description: binary() | nil
        }
end
