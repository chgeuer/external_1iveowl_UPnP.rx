defmodule UPnP.HTTP.Request do
  @moduledoc """
  A raw HTTP request. Methods are uppercase binaries so GENA verbs remain exact.
  """

  @enforce_keys [:method, :url]
  defstruct method: nil,
            url: nil,
            headers: [],
            body: nil,
            max_body_bytes: 2_097_152

  @type t :: %__MODULE__{
          method: String.t(),
          url: URI.t() | String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata() | nil,
          max_body_bytes: pos_integer()
        }
end
