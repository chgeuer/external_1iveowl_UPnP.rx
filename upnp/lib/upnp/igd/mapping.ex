defmodule UPnP.IGD.Mapping do
  @moduledoc "An immutable IGD port-mapping entry."

  @enforce_keys [:external_port, :internal_port, :protocol, :internal_client]
  defstruct remote_host: "",
            external_port: nil,
            protocol: nil,
            internal_port: nil,
            internal_client: nil,
            enabled: true,
            description: "",
            lease_duration: 0

  @type t :: %__MODULE__{
          remote_host: String.t(),
          external_port: :inet.port_number(),
          protocol: UPnP.IGD.Protocol.t(),
          internal_port: :inet.port_number(),
          internal_client: String.t(),
          enabled: boolean(),
          description: String.t(),
          lease_duration: non_neg_integer()
        }
end
