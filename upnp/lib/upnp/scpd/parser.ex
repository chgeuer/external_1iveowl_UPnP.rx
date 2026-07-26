defmodule UPnP.SCPD.Parser do
  @moduledoc "Pure, lenient parser for Service Control Protocol Descriptions."

  alias UPnP.{
    ActionDescription,
    AllowedValueRange,
    ArgumentDescription,
    ParseError,
    SCPD,
    SpecVersion,
    StateVariable,
    XML
  }

  @doc "Parses an SCPD XML document."
  @spec parse(binary()) :: {:ok, SCPD.t()} | {:error, ParseError.t()}
  def parse(xml) when is_binary(xml) do
    with {:ok, root} <- XML.parse(xml, :scpd) do
      {:ok,
       %SCPD{
         spec_version: parse_spec_version(root),
         actions: parse_actions(root),
         state_variables: parse_state_variables(root)
       }}
    end
  end

  @doc "Alias for `parse/1`."
  @spec parse_scpd(binary()) :: {:ok, SCPD.t()} | {:error, ParseError.t()}
  def parse_scpd(xml), do: parse(xml)

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

  defp parse_actions(root) do
    case XML.child(root, "actionList") do
      nil ->
        []

      action_list ->
        Enum.map(XML.children(action_list, "action"), fn action ->
          %ActionDescription{
            name: XML.child_token(action, "name"),
            arguments: parse_arguments(action)
          }
        end)
    end
  end

  defp parse_arguments(action) do
    case XML.child(action, "argumentList") do
      nil ->
        []

      argument_list ->
        Enum.map(XML.children(argument_list, "argument"), fn argument ->
          %ArgumentDescription{
            name: XML.child_token(argument, "name"),
            direction: parse_direction(XML.child_token(argument, "direction")),
            is_return_value: not is_nil(XML.child(argument, "retval")),
            related_state_variable: XML.child_token(argument, "relatedStateVariable")
          }
        end)
    end
  end

  defp parse_direction(nil), do: :unknown

  defp parse_direction(direction) do
    case String.downcase(direction) do
      "in" -> :in
      "out" -> :out
      _other -> :unknown
    end
  end

  defp parse_state_variables(root) do
    case XML.child(root, "serviceStateTable") do
      nil ->
        []

      state_table ->
        Enum.map(XML.children(state_table, "stateVariable"), &parse_state_variable/1)
    end
  end

  defp parse_state_variable(state_variable) do
    %StateVariable{
      name: XML.child_token(state_variable, "name"),
      data_type: XML.child_token(state_variable, "dataType"),
      default_value: XML.child_text(state_variable, "defaultValue"),
      sends_events: sends_events?(XML.attribute(state_variable, "sendEvents")),
      allowed_values: parse_allowed_values(state_variable),
      allowed_range: parse_allowed_range(state_variable)
    }
  end

  defp sends_events?(nil), do: true

  defp sends_events?(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 not in ["no", "false", "0"]))
  end

  defp parse_allowed_values(state_variable) do
    case XML.child(state_variable, "allowedValueList") do
      nil ->
        []

      value_list ->
        value_list
        |> XML.children("allowedValue")
        |> Enum.map(&XML.text_or_nil/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp parse_allowed_range(state_variable) do
    case XML.child(state_variable, "allowedValueRange") do
      nil ->
        nil

      range ->
        %AllowedValueRange{
          minimum: XML.child_token(range, "minimum"),
          maximum: XML.child_token(range, "maximum"),
          step: XML.child_token(range, "step")
        }
    end
  end
end
