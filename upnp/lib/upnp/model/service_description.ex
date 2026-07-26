defmodule UPnP.ServiceDescription do
  @moduledoc "A service advertised by a UPnP device."

  defstruct service_type: nil,
            service_id: nil,
            scpd_url: nil,
            control_url: nil,
            event_sub_url: nil

  @type t :: %__MODULE__{
          service_type: binary() | nil,
          service_id: binary() | nil,
          scpd_url: URI.t() | nil,
          control_url: URI.t() | nil,
          event_sub_url: URI.t() | nil
        }
end
