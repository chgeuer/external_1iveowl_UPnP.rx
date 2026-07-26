defmodule UpnpExplorer.DeviceView do
  @moduledoc """
  Stable, human-first projection of discovered and described UPnP devices.
  """

  alias UPnP.{DescribedDevice, Device, DeviceDescription}
  alias UpnpExplorer.ServiceView

  @enforce_keys [:id, :identity, :name, :location, :status]
  defstruct [
    :id,
    :identity,
    :name,
    :manufacturer,
    :model,
    :model_description,
    :serial_number,
    :device_type,
    :device_kind,
    :location,
    :host,
    :udn,
    :server,
    :boot_id,
    :config_id,
    :max_age,
    :local_address,
    :remote_endpoint,
    :icon_url,
    :presentation_url,
    :description_error,
    :last_seen_at,
    :search_text,
    :services,
    :nodes,
    :capabilities,
    status: :discovered,
    parsing_error?: false,
    service_count: 0,
    embedded_count: 0
  ]

  @type status :: :discovered | :describing | :online | :degraded
  @type t :: %__MODULE__{status: status()}

  @doc "Builds a partial view from an SSDP discovery envelope."
  @spec from_discovered(Device.t(), status()) :: t()
  def from_discovered(%Device{} = device, status \\ :describing) do
    identity = Device.identity(device)
    location = URI.to_string(device.location)
    host = device.location.host || location

    %__MODULE__{
      id: id_for_identity(identity),
      identity: identity,
      name: "Device at #{host}",
      location: location,
      host: host,
      udn: uuid_from_usn(device.usn),
      server: device.server,
      boot_id: device.boot_id,
      config_id: device.config_id,
      max_age: device.max_age,
      local_address: format_address(device.local_address),
      remote_endpoint: format_endpoint(device.remote_endpoint),
      last_seen_at: DateTime.utc_now(),
      parsing_error?: device.parsing_error?,
      status: status,
      services: [],
      nodes: [],
      capabilities: [],
      search_text: String.downcase("#{identity} #{location} #{device.server}")
    }
  end

  @doc """
  Builds a complete view and a lookup of projected service IDs to service clients.
  """
  @spec from_described(DescribedDevice.t()) :: {t(), %{binary() => UPnP.Service.t()}}
  def from_described(%DescribedDevice{} = described) do
    root = described.description

    owner_descriptions =
      root
      |> DeviceDescription.self_and_descendants()
      |> Enum.flat_map(fn owner -> Enum.map(owner.services, &{owner, &1}) end)

    projected_services =
      owner_descriptions
      |> Enum.zip(DescribedDevice.services(described))
      |> Enum.map(fn {{owner, _description}, service} ->
        {ServiceView.from_service(service, owner), service}
      end)

    services = Enum.map(projected_services, &elem(&1, 0))
    nodes = flatten_nodes(root)
    location = root.location || described.device.location
    host = location.host || URI.to_string(location)
    name = root.friendly_name || root.model_name || "Device at #{host}"

    capabilities =
      services
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()

    search_text =
      [
        name,
        root.manufacturer,
        root.model_name,
        root.device_type,
        root.udn,
        host,
        Enum.join(capabilities, " "),
        Enum.map_join(services, " ", & &1.service_type)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    view = %__MODULE__{
      id: id_for_identity(Device.identity(described.device)),
      identity: Device.identity(described.device),
      name: name,
      manufacturer: root.manufacturer,
      model: root.model_name,
      model_description: root.model_description,
      serial_number: root.serial_number,
      device_type: root.device_type,
      device_kind: human_device_type(root.device_type),
      location: URI.to_string(location),
      host: host,
      udn: root.udn,
      server: described.device.server,
      boot_id: described.device.boot_id,
      config_id: described.device.config_id || root.config_id,
      max_age: described.device.max_age,
      local_address: format_address(described.device.local_address),
      remote_endpoint: format_endpoint(described.device.remote_endpoint),
      icon_url: best_icon_url(root.icons),
      presentation_url: uri_string(root.presentation_url),
      last_seen_at: DateTime.utc_now(),
      parsing_error?: described.device.parsing_error?,
      status: :online,
      services: services,
      nodes: nodes,
      capabilities: capabilities,
      service_count: length(services),
      embedded_count: max(length(nodes) - 1, 0),
      search_text: search_text
    }

    {view, Map.new(projected_services, fn {summary, service} -> {summary.id, service} end)}
  end

  @doc "Returns the stable public ID for a discovered device."
  @spec id(Device.t()) :: binary()
  def id(%Device{} = device), do: id_for_identity(Device.identity(device))

  @doc "Reports whether the device matches a case-insensitive filter."
  @spec matches?(t(), binary()) :: boolean()
  def matches?(%__MODULE__{}, filter) when filter in [nil, ""], do: true

  def matches?(%__MODULE__{} = device, filter) do
    terms =
      filter
      |> String.trim()
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    Enum.all?(terms, &String.contains?(device.search_text || "", &1))
  end

  defp flatten_nodes(root) do
    root
    |> DeviceDescription.self_and_descendants()
    |> Enum.map(fn node ->
      %{
        id: stable_id("node", {node.udn, node.device_type, node.friendly_name}),
        name: node.friendly_name || human_device_type(node.device_type),
        device_type: node.device_type,
        manufacturer: node.manufacturer,
        model: node.model_name,
        udn: node.udn,
        service_count: length(node.services),
        embedded_count: length(node.embedded_devices)
      }
    end)
  end

  defp best_icon_url(icons) do
    icons
    |> Enum.filter(&match?(%URI{}, &1.url))
    |> Enum.max_by(&((&1.width || 0) * (&1.height || 0)), fn -> nil end)
    |> case do
      nil -> nil
      icon -> URI.to_string(icon.url)
    end
  end

  defp human_device_type(nil), do: "UPnP device"

  defp human_device_type(device_type) do
    token =
      device_type
      |> String.split(":")
      |> Enum.reverse()
      |> Enum.find(fn part -> part != "" and not version_token?(part) end)

    case token do
      nil -> "UPnP device"
      "InternetGatewayDevice" -> "Internet gateway"
      "MediaRenderer" -> "Media renderer"
      "MediaServer" -> "Media server"
      value -> value |> Macro.underscore() |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp version_token?(token), do: match?({_version, ""}, Integer.parse(token))

  defp id_for_identity(identity), do: stable_id("device", String.downcase(identity))

  defp stable_id(prefix, value) do
    digest =
      value
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 12)
      |> Base.url_encode64(padding: false)

    "#{prefix}-#{digest}"
  end

  defp uuid_from_usn(nil), do: nil
  defp uuid_from_usn(usn), do: usn |> String.split("::", parts: 2) |> List.first()

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(_uri), do: nil

  defp format_address(nil), do: nil
  defp format_address(address), do: address |> :inet.ntoa() |> IO.iodata_to_binary()

  defp format_endpoint(nil), do: nil

  defp format_endpoint({address, port}) do
    "#{format_address(address)}:#{port}"
  end
end
