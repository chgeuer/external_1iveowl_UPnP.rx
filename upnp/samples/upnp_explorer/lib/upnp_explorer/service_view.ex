defmodule UpnpExplorer.ServiceView do
  @moduledoc """
  Human-readable projection of one UPnP service and its optional SCPD.
  """

  alias UPnP.{ActionResult, DeviceDescription, Service}
  alias UpnpExplorer.ActionPolicy

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

  @integer_types ~w(ui1 ui2 ui4 ui8 i1 i2 i4 i8 int)
  @numeric_types @integer_types ++ ~w(r4 r8 number float fixed.14.4)

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

  @doc "Returns a readable capability name from a service type."
  @spec capability_name(binary() | nil) :: binary()
  def capability_name(service_type) do
    token = service_token(service_type, nil)
    Map.get(@capability_names, token, humanize(token || "Unknown service"))
  end

  @doc "Projects a SOAP result in declared output order, followed by device extensions."
  @spec action_result(map(), ActionResult.t()) :: map()
  def action_result(action, %ActionResult{} = result) do
    declared_names =
      action.outputs
      |> Enum.map(& &1.wire_name)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&normalize/1)

    declared =
      Enum.map(action.outputs, fn output ->
        value =
          if output.wire_name do
            ActionResult.get(result, output.wire_name)
          end

        %{
          id: stable_id("result", {action.id, output.id}),
          name: output.name,
          value: value,
          returned?: is_binary(value),
          declared?: true
        }
      end)

    extras =
      result.out
      |> Enum.filter(fn
        {name, value} when is_binary(name) and is_binary(value) ->
          not MapSet.member?(declared_names, normalize(name))

        _entry ->
          false
      end)
      |> Enum.sort_by(fn {name, _value} -> normalize(name) end)
      |> Enum.map(fn {name, value} ->
        %{
          id: stable_id("result", {action.id, normalize(name)}),
          name: name,
          value: value,
          returned?: true,
          declared?: false
        }
      end)

    %{outputs: declared ++ extras, empty?: result.out == %{}}
  end

  defp action_view(action, variables, summary) do
    wire_name = usable_name(action.name)

    inputs =
      action.arguments
      |> Enum.filter(&(&1.direction == :in))
      |> Enum.map(&argument_view(&1, variables, summary.id, wire_name, :in))

    outputs =
      action.arguments
      |> Enum.filter(&(&1.direction == :out))
      |> Enum.map(&argument_view(&1, variables, summary.id, wire_name, :out))

    %{
      id: stable_id("action", {summary.id, action.name}),
      name: wire_name || "(unnamed action)",
      wire_name: wire_name,
      invokable?: not is_nil(wire_name),
      inputs: inputs,
      outputs: outputs,
      policy: ActionPolicy.classify(summary.service_type, wire_name, inputs),
      operation_status: :idle,
      operation_result: nil,
      operation_error: nil,
      pending_arguments: %{}
    }
  end

  defp argument_view(argument, variables, service_id, action_name, direction) do
    related = Map.get(variables, normalize(argument.related_state_variable))
    range = related && related.allowed_range
    data_type = related && related.data_type
    wire_name = usable_name(argument.name)
    allowed_values = (related && related.allowed_values) || []
    input_type = input_type(data_type, allowed_values)

    %{
      id: stable_id("argument", {service_id, action_name, direction, argument.name}),
      name: wire_name || "(unnamed)",
      wire_name: wire_name,
      data_type: data_type,
      default_value: related && related.default_value,
      suggested_value:
        suggested_value(wire_name, data_type, related && related.default_value, allowed_values),
      allowed_values: allowed_values,
      input_type: input_type,
      options: input_options(input_type, allowed_values),
      minimum: numeric_constraint(input_type, range && range.minimum),
      maximum: numeric_constraint(input_type, range && range.maximum),
      step: numeric_step(input_type, data_type, range && range.step),
      return_value?: argument.is_return_value
    }
  end

  defp input_type(_data_type, allowed_values) when allowed_values != [], do: "select"

  defp input_type(data_type, _allowed_values) when is_binary(data_type) do
    case String.downcase(data_type) do
      type when type in ["boolean", "bool"] -> "select"
      type when type in @numeric_types -> "number"
      _type -> "text"
    end
  end

  defp input_type(_data_type, _allowed_values), do: "text"

  defp input_options("select", _allowed_values = []) do
    [{"True", "1"}, {"False", "0"}]
  end

  defp input_options("select", allowed_values) do
    Enum.map(allowed_values, &{&1, &1})
  end

  defp input_options(_input_type, _allowed_values), do: []

  defp suggested_value(name, data_type, default_value, allowed_values) do
    cond do
      boolean_type?(data_type) -> normalize_boolean(default_value)
      is_binary(default_value) -> default_value
      allowed_values != [] -> hd(allowed_values)
      normalize(name) == "instanceid" -> "0"
      true -> ""
    end
  end

  defp normalize_boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      truthy when truthy in ["1", "true", "yes"] -> "1"
      falsy when falsy in ["0", "false", "no"] -> "0"
      _value -> "0"
    end
  end

  defp normalize_boolean(_value), do: "0"

  defp boolean_type?(data_type) when is_binary(data_type),
    do: String.downcase(data_type) in ["boolean", "bool"]

  defp boolean_type?(_data_type), do: false

  defp numeric_constraint("number", value), do: valid_number(value)
  defp numeric_constraint(_input_type, _value), do: nil

  defp numeric_step("number", data_type, nil) do
    if is_binary(data_type) and String.downcase(data_type) in @integer_types, do: "1", else: "any"
  end

  defp numeric_step("number", _data_type, value), do: valid_number(value) || "any"
  defp numeric_step(_input_type, _data_type, _value), do: nil

  defp valid_number(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/, value), do: value
  end

  defp valid_number(_value), do: nil

  defp usable_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      name -> name
    end
  end

  defp usable_name(_value), do: nil

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
