defmodule UPnP.Samples.DeviceTree do
  @moduledoc false

  alias UPnP.DeviceDescription

  @spec render(DeviceDescription.t()) :: String.t()
  def render(%DeviceDescription{} = device) do
    friendly_name = device.friendly_name || "(unnamed device)"

    [
      friendly_name,
      "  [",
      format_uri(device.location),
      "]\n",
      render_device(device, "", ""),
      "\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_device(device, connector, child_prefix) do
    children =
      Enum.map(device.services, &{:service, &1}) ++
        Enum.map(device.embedded_devices, &{:device, &1})

    [
      connector,
      device.device_type || "(no deviceType)",
      maker(device),
      "\n",
      render_children(children, child_prefix)
    ]
  end

  defp render_children(children, child_prefix) do
    last_index = length(children) - 1

    children
    |> Enum.with_index()
    |> Enum.map(fn
      {{:service, service}, index} ->
        connector = if index == last_index, do: "└─ ", else: "├─ "
        [child_prefix, connector, "· ", service.service_type || "(no serviceType)", "\n"]

      {{:device, device}, index} ->
        last? = index == last_index
        connector = child_prefix <> if(last?, do: "└─ ", else: "├─ ")
        next_prefix = child_prefix <> if(last?, do: "   ", else: "│  ")
        render_device(device, connector, next_prefix)
    end)
  end

  defp maker(device) do
    value =
      [device.manufacturer, device.model_name]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map_join(" ", &String.trim/1)

    if value == "", do: "", else: "  (#{value})"
  end

  defp format_uri(%URI{} = uri), do: URI.to_string(uri)
  defp format_uri(nil), do: "(no location)"
end
