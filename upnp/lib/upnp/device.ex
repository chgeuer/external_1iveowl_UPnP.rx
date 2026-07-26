defmodule UPnP.Device do
  @moduledoc """
  An immutable device discovery envelope.
  """

  @enforce_keys [:location]
  defstruct location: nil,
            usn: nil,
            server: nil,
            boot_id: nil,
            config_id: nil,
            max_age: nil,
            local_address: nil,
            remote_endpoint: nil,
            parsing_error?: false

  @type t :: %__MODULE__{
          location: URI.t(),
          usn: String.t() | nil,
          server: String.t() | nil,
          boot_id: non_neg_integer() | nil,
          config_id: non_neg_integer() | nil,
          max_age: non_neg_integer() | nil,
          local_address: :inet.ip4_address() | nil,
          remote_endpoint: {:inet.ip_address(), :inet.port_number()} | nil,
          parsing_error?: boolean()
        }

  @doc "Returns a stable roster key, preferring the UUID portion of USN."
  @spec identity(t()) :: String.t()
  def identity(%__MODULE__{usn: usn, location: location}) do
    case usn && String.split(usn, "::", parts: 2) do
      [uuid | _] when uuid != "" -> String.downcase(uuid)
      _ -> URI.to_string(location)
    end
  end

  @doc "Returns an identity scoped to one boot instance."
  @spec boot_identity(t()) :: {String.t(), non_neg_integer() | nil}
  def boot_identity(device), do: {identity(device), device.boot_id}
end
