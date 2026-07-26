defmodule UPnP.DeviceDescription do
  @moduledoc "An immutable device description, including its embedded device tree."

  defstruct location: nil,
            base_url: nil,
            spec_version: nil,
            config_id: nil,
            device_type: nil,
            friendly_name: nil,
            udn: nil,
            manufacturer: nil,
            manufacturer_url: nil,
            model_description: nil,
            model_name: nil,
            model_number: nil,
            model_url: nil,
            serial_number: nil,
            upc: nil,
            presentation_url: nil,
            icons: [],
            services: [],
            embedded_devices: []

  @type t :: %__MODULE__{
          location: URI.t() | nil,
          base_url: URI.t() | nil,
          spec_version: UPnP.SpecVersion.t() | nil,
          config_id: integer() | nil,
          device_type: binary() | nil,
          friendly_name: binary() | nil,
          udn: binary() | nil,
          manufacturer: binary() | nil,
          manufacturer_url: binary() | nil,
          model_description: binary() | nil,
          model_name: binary() | nil,
          model_number: binary() | nil,
          model_url: binary() | nil,
          serial_number: binary() | nil,
          upc: binary() | nil,
          presentation_url: URI.t() | nil,
          icons: [UPnP.IconDescription.t()],
          services: [UPnP.ServiceDescription.t()],
          embedded_devices: [t()]
        }

  @doc "Returns this device and every embedded device in depth-first order."
  @spec self_and_descendants(t()) :: [t()]
  def self_and_descendants(%__MODULE__{} = device) do
    [device | Enum.flat_map(device.embedded_devices, &self_and_descendants/1)]
  end
end
