defmodule UpnpExplorer.Gateway do
  @moduledoc "Read-only projection of the local Internet Gateway Device."

  alias UPnP.IGD
  alias UPnP.IGD.{Gateway, Protocol, Status}

  @doc "Discovers the gateway and reads its current WAN and mapping state."
  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case UPnP.ControlPoint.whereis(UpnpExplorer.ControlPoint) do
      nil ->
        {:error, :network_unavailable}

      _pid ->
        load(UpnpExplorer.ControlPoint)
    end
  end

  @doc false
  @spec load(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def load(control_point) do
    with {:ok, gateway} <- IGD.discover_gateway(control_point, mx: 3) do
      case gateway do
        nil -> {:ok, %{state: :not_found, mappings: []}}
        gateway -> {:ok, gateway_view(gateway)}
      end
    end
  end

  defp gateway_view(gateway) do
    description = gateway.device.description

    %{
      state: :ready,
      name: description.friendly_name || "Internet gateway",
      manufacturer: description.manufacturer,
      model: description.model_name,
      service_type: gateway.wan_service.description.service_type,
      local_address: format_address(gateway.local_address),
      status: tagged(Gateway.status(gateway)),
      external_address: tagged_address(Gateway.external_address(gateway)),
      mappings: mapping_views(Gateway.list_port_mappings(gateway, max_entries: 256))
    }
  end

  defp mapping_views({:ok, mappings}) do
    Enum.map(mappings, fn mapping ->
      %{
        id: "mapping-#{Protocol.to_wire(mapping.protocol)}-#{mapping.external_port}",
        protocol: Protocol.to_wire(mapping.protocol),
        external_port: mapping.external_port,
        internal_port: mapping.internal_port,
        internal_client: mapping.internal_client,
        enabled?: mapping.enabled,
        description: mapping.description,
        lease_duration: mapping.lease_duration
      }
    end)
  end

  defp mapping_views({:error, reason}), do: {:error, reason}

  defp tagged({:ok, %Status{} = status}) do
    {:ok,
     %{
       label: status.status || "Unknown",
       connected?: Status.connected?(status),
       last_error: status.last_error,
       uptime: status.uptime
     }}
  end

  defp tagged({:error, reason}), do: {:error, reason}

  defp tagged_address({:ok, address}), do: {:ok, format_address(address)}
  defp tagged_address({:error, reason}), do: {:error, reason}

  defp format_address(nil), do: nil
  defp format_address(address), do: address |> :inet.ntoa() |> IO.iodata_to_binary()
end
