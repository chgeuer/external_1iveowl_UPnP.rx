defmodule UPnP.Description.Parser do
  @moduledoc """
  Pure, lenient parser for UPnP device description documents.
  """

  alias UPnP.{
    DeviceDescription,
    IconDescription,
    ParseError,
    ServiceDescription,
    SpecVersion,
    XML
  }

  @doc "Parses a device description fetched from `location`."
  @spec parse(binary(), binary() | URI.t()) ::
          {:ok, DeviceDescription.t()} | {:error, ParseError.t()}
  def parse(xml, location) when is_binary(xml) and is_binary(location) do
    parse_with_location(xml, XML.absolute_http_uri(String.trim(location)))
  end

  def parse(xml, %URI{} = location) when is_binary(xml) do
    parse_with_location(xml, XML.absolute_http_uri(location))
  end

  @doc "Alias for `parse/2`."
  @spec parse_device_description(binary(), binary() | URI.t()) ::
          {:ok, DeviceDescription.t()} | {:error, ParseError.t()}
  def parse_device_description(xml, location), do: parse(xml, location)

  defp parse_with_location(_xml, nil) do
    {:error,
     %ParseError{
       source: :device_description,
       message: "location must be an absolute HTTP(S) URI",
       reason: :invalid_location
     }}
  end

  defp parse_with_location(xml, %URI{} = location) do
    with {:ok, root} <- XML.parse(xml, :device_description),
         {:ok, device_element} <- find_device(root) do
      base_url = description_base(root, location)
      spec_version = parse_spec_version(root)
      config_id = non_negative_attribute_integer(root, "configId")

      {:ok, parse_device(device_element, location, base_url, spec_version, config_id)}
    end
  end

  defp find_device({name, _attributes, _content} = root) do
    cond do
      XML.name?(name, "device") ->
        {:ok, root}

      device = XML.child(root, "device") ->
        {:ok, device}

      true ->
        {:error,
         %ParseError{
           source: :device_description,
           message: "document contains no device element",
           reason: :missing_device
         }}
    end
  end

  defp description_base(root, location) do
    root
    |> XML.child_token("URLBase")
    |> XML.absolute_http_uri()
    |> case do
      nil -> location
      url_base -> url_base
    end
  end

  defp parse_spec_version(root) do
    with {_name, _attributes, _content} = version <- XML.child(root, "specVersion"),
         major when is_integer(major) and major >= 0 <- XML.child_integer(version, "major") do
      minor =
        case XML.child_integer(version, "minor") do
          value when is_integer(value) and value >= 0 -> value
          _other -> 0
        end

      %SpecVersion{major: major, minor: minor}
    else
      _other -> nil
    end
  end

  defp parse_device(device, location, base_url, spec_version, config_id) do
    %DeviceDescription{
      location: location,
      base_url: base_url,
      spec_version: spec_version,
      config_id: config_id,
      device_type: XML.child_token(device, "deviceType"),
      friendly_name: XML.child_text(device, "friendlyName"),
      udn: XML.child_token(device, "UDN"),
      manufacturer: XML.child_text(device, "manufacturer"),
      manufacturer_url: XML.child_text(device, "manufacturerURL"),
      model_description: XML.child_text(device, "modelDescription"),
      model_name: XML.child_text(device, "modelName"),
      model_number: XML.child_text(device, "modelNumber"),
      model_url: XML.child_text(device, "modelURL"),
      serial_number: XML.child_text(device, "serialNumber"),
      upc: XML.child_text(device, "UPC"),
      presentation_url: resolve_child_url(device, "presentationURL", base_url),
      icons: parse_icons(device, base_url),
      services: parse_services(device, base_url),
      embedded_devices:
        parse_embedded_devices(
          device,
          location,
          base_url,
          spec_version,
          config_id
        )
    }
  end

  defp parse_icons(device, base_url) do
    case XML.child(device, "iconList") do
      nil ->
        []

      icon_list ->
        Enum.map(XML.children(icon_list, "icon"), fn icon ->
          %IconDescription{
            mime_type: XML.child_text(icon, "mimetype"),
            width: non_negative_child_integer(icon, "width"),
            height: non_negative_child_integer(icon, "height"),
            depth: non_negative_child_integer(icon, "depth"),
            url: resolve_child_url(icon, "url", base_url)
          }
        end)
    end
  end

  defp parse_services(device, base_url) do
    case XML.child(device, "serviceList") do
      nil ->
        []

      service_list ->
        Enum.map(XML.children(service_list, "service"), fn service ->
          %ServiceDescription{
            service_type: XML.child_token(service, "serviceType"),
            service_id: XML.child_token(service, "serviceId"),
            scpd_url: resolve_child_url(service, "SCPDURL", base_url),
            control_url: resolve_child_url(service, "controlURL", base_url),
            event_sub_url: resolve_child_url(service, "eventSubURL", base_url)
          }
        end)
    end
  end

  defp parse_embedded_devices(
         device,
         location,
         base_url,
         spec_version,
         config_id
       ) do
    case XML.child(device, "deviceList") do
      nil ->
        []

      device_list ->
        Enum.map(XML.children(device_list, "device"), fn embedded ->
          parse_device(
            embedded,
            location,
            base_url,
            spec_version,
            config_id
          )
        end)
    end
  end

  defp resolve_child_url(element, child_name, base_url) do
    element
    |> XML.child_token(child_name)
    |> then(&XML.resolve_url(base_url, &1))
  end

  defp non_negative_child_integer(element, child_name) do
    case XML.child_integer(element, child_name) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp non_negative_attribute_integer(element, attribute_name) do
    case XML.attribute_integer(element, attribute_name) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end
end
