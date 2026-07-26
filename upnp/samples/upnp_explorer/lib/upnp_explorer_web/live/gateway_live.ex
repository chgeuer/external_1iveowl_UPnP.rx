defmodule UpnpExplorerWeb.GatewayLive do
  @moduledoc "Read-only Internet Gateway Device inventory."

  use UpnpExplorerWeb, :live_view

  import UpnpExplorerWeb.ExplorerComponents

  alias UpnpExplorer.Gateway

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Gateway",
        loading?: true,
        gateway: nil,
        error: nil,
        mapping_error: nil
      )
      |> stream_configure(:mappings, dom_id: & &1.id)
      |> stream(:mappings, [])

    socket = if connected?(socket), do: load_gateway(socket), else: socket
    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_gateway(socket)}
  end

  @impl true
  def handle_async(:load_gateway, {:ok, {:ok, gateway}}, socket) do
    {mappings, mapping_error} =
      case gateway.mappings do
        {:error, reason} -> {[], format_reason(reason)}
        values when is_list(values) -> {values, nil}
      end

    {:noreply,
     socket
     |> assign(
       loading?: false,
       gateway: gateway,
       error: nil,
       mapping_error: mapping_error
     )
     |> stream(:mappings, mappings, reset: true)}
  end

  def handle_async(:load_gateway, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       loading?: false,
       gateway: nil,
       error: format_reason(reason)
     )}
  end

  def handle_async(:load_gateway, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       loading?: false,
       gateway: nil,
       error: format_reason(reason)
     )}
  end

  defp load_gateway(socket) do
    socket
    |> assign(loading?: true, error: nil, mapping_error: nil)
    |> start_async(:load_gateway, &Gateway.load/0)
  end

  defp status_label({:ok, status}), do: status.label
  defp status_label({:error, _reason}), do: "Unavailable"

  defp status_connected?({:ok, status}), do: status.connected?
  defp status_connected?({:error, _reason}), do: false

  defp status_uptime({:ok, status}), do: format_duration(status.uptime)
  defp status_uptime({:error, reason}), do: format_reason(reason)

  defp external_address({:ok, address}), do: address
  defp external_address({:error, reason}), do: format_reason(reason)

  defp format_lease(0), do: "Indefinite"
  defp format_lease(seconds), do: format_duration(seconds)

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    minutes = div(rem(seconds, 3_600), 60)

    [
      days > 0 && "#{days}d",
      hours > 0 && "#{hours}h",
      (minutes > 0 || seconds == 0) && "#{minutes}m"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_reason(reason) do
    case reason do
      exception when is_exception(exception) -> Exception.message(exception)
      value -> inspect(value, pretty: true, limit: 8, printable_limit: 220)
    end
  end
end
