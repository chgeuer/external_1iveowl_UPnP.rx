defmodule UPnP.SSDP.Envelope do
  @moduledoc """
  A parsed SSDP search response or presence notification.
  """

  @enforce_keys [:kind]
  defstruct kind: nil,
            headers: %{},
            location: nil,
            usn: nil,
            search_target: nil,
            notification_type: nil,
            server: nil,
            boot_id: nil,
            config_id: nil,
            max_age: nil,
            parsing_error?: false,
            remote_endpoint: nil,
            local_address: nil

  @type kind :: :search_response | :alive | :byebye
  @type t :: %__MODULE__{
          kind: kind(),
          headers: %{String.t() => String.t()},
          location: URI.t() | nil,
          usn: String.t() | nil,
          search_target: String.t() | nil,
          notification_type: String.t() | nil,
          server: String.t() | nil,
          boot_id: non_neg_integer() | nil,
          config_id: non_neg_integer() | nil,
          max_age: non_neg_integer() | nil,
          parsing_error?: boolean(),
          remote_endpoint: {:inet.ip_address(), :inet.port_number()} | nil,
          local_address: :inet.ip_address() | nil
        }
end
