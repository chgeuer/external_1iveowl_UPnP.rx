defmodule UPnP.IconDescription do
  @moduledoc "An icon advertised by a UPnP device."

  defstruct mime_type: nil, width: nil, height: nil, depth: nil, url: nil

  @type t :: %__MODULE__{
          mime_type: binary() | nil,
          width: integer() | nil,
          height: integer() | nil,
          depth: integer() | nil,
          url: URI.t() | nil
        }
end
