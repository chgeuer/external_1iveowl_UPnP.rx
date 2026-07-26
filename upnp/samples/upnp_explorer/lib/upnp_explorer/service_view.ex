defmodule UpnpExplorer.ServiceView do
  @moduledoc """
  Human-readable projection of one UPnP service and its optional SCPD.
  """

  alias UPnP.{DeviceDescription, Service}

  @enforce_keys [:id, :name, :service_type, :owner_name]
  defstruct [
    :id,
    :name,
    :service_type,
    :service_id,
    :version,
    :owner_name,
    :owner_udn,
    :scpd_url,
    :control_url,
    :event_url,
    evented?: false
  ]

  @type t :: %__MODULE__{}

  @capability_names %{
    "AVTransport" => "Media playback",
    "ConnectionManager" => "Media connections",
    "ContentDirectory" => "Media library",
    "Dimming" => "Dimming",
    "RenderingControl" => "Audio and display",
    "SwitchPower" => "Power",
    "WANCommonInterfaceConfig" => "WAN interface",
    "WANIPConnection" => "Internet connection",
    "WANPPPConnection" => "Internet connection"
  }

  @read_only_queries %{
    {"WANIPConnection", "GetExternalIPAddress"} => %{
      button_label: "Query current address",
      result_label: "External IP address"
    },
    {"WANPPPConnection", "GetExternalIPAddress"} => %{
      button_label: "Query current address",
      result_label: "External IP address"
    }
  }

  @doc "Projects a service client together with the device node that owns it."
  @spec from_service(Service.t(), DeviceDescription.t()) :: t()
  def from_service(%Service{} = service, %DeviceDescription{} = owner) do
    description = service.description
    token = service_token(description.service_type, description.service_id)

    %__MODULE__{
      id: stable_id("service", {owner.udn, description.service_id, description.service_type}),
      name: Map.get(@capability_names, token, humanize(token || "Unknown service")),
      service_type: description.service_type || "unknown",
      service_id: description.service_id,
      version: service_version(description.service_type),
      owner_name: owner.friendly_name || humanize(device_token(owner.device_type) || "Device"),
      owner_udn: owner.udn,
      scpd_url: uri_string(description.scpd_url),
      control_url: uri_string(description.control_url),
      event_url: uri_string(description.event_sub_url),
      evented?: match?(%URI{}, description.event_sub_url)
    }
  end

  @doc "Loads and projects the service's SCPD."
  @spec detail(Service.t(), t()) :: {:ok, map()} | {:error, term()}
  def detail(%Service{} = service, %__MODULE__{} = summary) do
    with {:ok, scpd} <- Service.get_scpd(service) do
      variables = Map.new(scpd.state_variables, &{normalize(&1.name), &1})

      {:ok,
       %{
         summary: summary,
         actions: Enum.map(scpd.actions, &action_view(&1, variables, summary)),
         state_variables: Enum.map(scpd.state_variables, &state_variable_view(&1, summary.id))
       }}
    end
  end

  @doc "Returns UI metadata for an allowlisted read-only service query."
  @spec read_only_query(t(), binary()) :: map() | nil
  def read_only_query(%__MODULE__{} = summary, action_name) when is_binary(action_name) do
    Map.get(@read_only_queries, {service_token(summary.service_type, nil), action_name})
  end

  @doc "Returns a readable capability name from a service type."
  @spec capability_name(binary() | nil) :: binary()
  def capability_name(service_type) do
    token = service_token(service_type, nil)
    Map.get(@capability_names, token, humanize(token || "Unknown service"))
  end

  defp action_view(action, variables, summary) do
    inputs =
      action.arguments
      |> Enum.filter(&(&1.direction == :in))
      |> Enum.map(&argument_view(&1, variables))

    %{
      id: stable_id("action", {summary.id, action.name}),
      name: action.name || "(unnamed action)",
      inputs: inputs,
      outputs:
        action.arguments
        |> Enum.filter(&(&1.direction == :out))
        |> Enum.map(&argument_view(&1, variables)),
      read_only_query:
        if(inputs == [], do: read_only_query(summary, action.name || ""), else: nil),
      query_status: :idle,
      query_result: nil,
      query_error: nil
    }
  end

  defp argument_view(argument, variables) do
    related = Map.get(variables, normalize(argument.related_state_variable))
    range = related && related.allowed_range

    %{
      name: argument.name || "(unnamed)",
      data_type: related && related.data_type,
      default_value: related && related.default_value,
      allowed_values: (related && related.allowed_values) || [],
      minimum: range && range.minimum,
      maximum: range && range.maximum,
      step: range && range.step,
      return_value?: argument.is_return_value
    }
  end

  defp state_variable_view(variable, service_id) do
    range = variable.allowed_range

    %{
      id: stable_id("variable", {service_id, variable.name}),
      name: variable.name || "(unnamed variable)",
      data_type: variable.data_type || "string",
      default_value: variable.default_value,
      sends_events?: variable.sends_events,
      allowed_values: variable.allowed_values,
      minimum: range && range.minimum,
      maximum: range && range.maximum,
      step: range && range.step
    }
  end

  defp service_token(service_type, service_id) do
    Enum.find_value([service_type, service_id], fn
      value when is_binary(value) ->
        value
        |> String.split(":")
        |> Enum.reverse()
        |> Enum.find(fn part -> part != "" and not version_token?(part) end)

      _value ->
        nil
    end)
  end

  defp device_token(nil), do: nil

  defp device_token(device_type) do
    device_type
    |> String.split(":")
    |> Enum.reverse()
    |> Enum.find(fn part -> part != "" and not version_token?(part) end)
  end

  defp service_version(nil), do: nil

  defp service_version(service_type) do
    case service_type |> String.split(":") |> List.last() |> Integer.parse() do
      {version, ""} -> version
      _result -> nil
    end
  end

  defp version_token?(token) do
    match?({_version, ""}, Integer.parse(token))
  end

  defp humanize(value) do
    value
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp normalize(nil), do: ""
  defp normalize(value), do: value |> String.trim() |> String.downcase()

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(_uri), do: nil

  defp stable_id(prefix, value) do
    digest =
      value
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 12)
      |> Base.url_encode64(padding: false)

    "#{prefix}-#{digest}"
  end
end
