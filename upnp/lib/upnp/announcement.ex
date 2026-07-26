defmodule UPnP.Announcement do
  @moduledoc "One parsed SSDP activity item."

  @enforce_keys [:kind, :device, :received_at]
  defstruct [:kind, :device, :received_at]

  @type t :: %__MODULE__{
          kind: :search_response | :alive | :byebye,
          device: UPnP.Device.t(),
          received_at: DateTime.t()
        }
end
