defmodule UPnP.IGD do
  @moduledoc """
  Discovery helpers for Internet Gateway Devices.
  """

  alias UPnP.{ControlPoint, Device}
  alias UPnP.IGD.Gateway
  alias UPnP.SSDP.SearchTarget

  @targets [
    SearchTarget.device_type("InternetGatewayDevice", 2),
    SearchTarget.device_type("InternetGatewayDevice", 1)
  ]

  @doc """
  Discovers and describes the first device with a usable WAN connection service.

  Description failures and non-IGD responses are skipped. `{:ok, nil}` means no
  usable gateway answered either search.
  """
  @spec discover_gateway(GenServer.server(), keyword()) ::
          {:ok, Gateway.t() | nil} | {:error, term()}
  def discover_gateway(control_point, options \\ []) do
    mx = Keyword.get(options, :mx, 3)

    case ControlPoint.roster(control_point) do
      {:error, _reason} = error -> error
      devices -> discover_from_roster(control_point, devices, mx)
    end
  end

  defp discover_from_roster(control_point, devices, mx) do
    case resolve_first(control_point, devices) do
      {:ok, %Gateway{} = gateway} -> {:ok, gateway}
      {:ok, nil} -> search_targets(control_point, @targets, mx, MapSet.new())
    end
  end

  @doc """
  Resolves an already discovered device as an internet gateway.
  """
  @spec from_device(GenServer.server(), Device.t()) ::
          {:ok, Gateway.t()} | {:error, term()}
  def from_device(control_point, %Device{} = device) do
    with {:ok, described} <- ControlPoint.describe(control_point, device),
         {:ok, gateway} <- Gateway.new(described) do
      {:ok, gateway}
    end
  end

  defp search_targets(_control_point, [], _mx, _seen), do: {:ok, nil}

  defp search_targets(control_point, [target | targets], mx, seen) do
    with {:ok, found} <- ControlPoint.discover(control_point, target: target, mx: mx) do
      candidates = Enum.reject(found, &MapSet.member?(seen, Device.identity(&1)))

      case resolve_first(control_point, candidates) do
        {:ok, %Gateway{} = gateway} ->
          {:ok, gateway}

        {:ok, nil} ->
          seen = Enum.reduce(candidates, seen, &MapSet.put(&2, Device.identity(&1)))
          search_targets(control_point, targets, mx, seen)
      end
    end
  end

  defp resolve_first(control_point, devices) do
    Enum.reduce_while(devices, {:ok, nil}, fn device, _result ->
      case from_device(control_point, device) do
        {:ok, gateway} -> {:halt, {:ok, gateway}}
        {:error, _reason} -> {:cont, {:ok, nil}}
      end
    end)
  end
end
