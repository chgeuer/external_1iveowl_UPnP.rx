defmodule UPnP.DescribedDevice do
  @moduledoc """
  A discovered device paired with its parsed description and service clients.
  """

  alias UPnP.{Device, DeviceDescription, Service, ServiceDescription}

  @enforce_keys [:control_point, :device, :description]
  defstruct [:control_point, :device, :description]

  @type t :: %__MODULE__{
          control_point: GenServer.server(),
          device: Device.t(),
          description: DeviceDescription.t()
        }

  @doc "Returns service clients for this device and all embedded devices."
  @spec services(t()) :: [Service.t()]
  def services(%__MODULE__{} = device) do
    scope = cache_scope(device)

    device.description
    |> DeviceDescription.self_and_descendants()
    |> Enum.flat_map(& &1.services)
    |> Enum.map(fn description ->
      Service.new(
        device.control_point,
        description,
        scope,
        device.device.local_address
      )
    end)
  end

  @doc "Finds a service by its complete service type or service ID."
  @spec service(t(), binary()) :: {:ok, Service.t()} | {:error, {:service_not_found, binary()}}
  def service(%__MODULE__{} = device, service_type_or_id)
      when is_binary(service_type_or_id) do
    case Enum.find(services(device), &service_matches?(&1.description, service_type_or_id)) do
      nil -> {:error, {:service_not_found, service_type_or_id}}
      service -> {:ok, service}
    end
  end

  @doc "Reports whether a complete service type or service ID is present."
  @spec has_service?(t(), binary()) :: boolean()
  def has_service?(%__MODULE__{} = device, service_type_or_id)
      when is_binary(service_type_or_id) do
    match?({:ok, _service}, service(device, service_type_or_id))
  end

  defp cache_scope(device) do
    {
      URI.to_string(device.device.location),
      device.device.config_id || device.description.config_id,
      device.device.boot_id
    }
  end

  defp service_matches?(%ServiceDescription{} = service, query) do
    normalized_query = normalize(query)

    Enum.any?([service.service_type, service.service_id], fn
      value when is_binary(value) -> normalize(value) == normalized_query
      _value -> false
    end)
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
