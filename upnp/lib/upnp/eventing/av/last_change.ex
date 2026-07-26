defmodule UPnP.Eventing.AV.LastChange do
  @moduledoc "Pure parser for UPnP AV LastChange XML payloads."

  alias UPnP.Eventing.AV.PropertyChange
  alias UPnP.{ParseError, XML}

  @doc "Parses per-instance variable changes from a decoded LastChange value."
  @spec parse(binary()) :: {:ok, [PropertyChange.t()]} | {:error, ParseError.t()}
  def parse(xml) when is_binary(xml) do
    with {:ok, root} <- XML.parse(xml, :av_last_change) do
      event = XML.find_first(root, "Event") || root

      changes =
        if instance_id_element?(event) do
          parse_instance(event)
        else
          Enum.flat_map(element_children(event), &parse_event_child/1)
        end

      {:ok, changes}
    end
  end

  defp parse_event_child(element) do
    if instance_id_element?(element) do
      parse_instance(element)
    else
      [to_change(element, 0)]
    end
  end

  defp parse_instance(instance) do
    instance_id =
      case XML.attribute(instance, "val") do
        nil ->
          0

        value ->
          case value |> String.trim() |> Integer.parse() do
            {id, ""} when id >= 0 -> id
            _other -> 0
          end
      end

    Enum.map(element_children(instance), &to_change(&1, instance_id))
  end

  defp to_change({name, _attributes, _content} = variable, instance_id) do
    value =
      case XML.attribute(variable, "val") do
        nil -> variable |> XML.text() |> String.trim()
        attribute_value -> attribute_value
      end

    %PropertyChange{
      instance_id: instance_id,
      name: XML.local_name(name),
      value: value,
      channel: XML.attribute(variable, "channel")
    }
  end

  defp instance_id_element?({name, _attributes, _content}) do
    XML.name?(name, "InstanceID")
  end

  defp element_children({_name, _attributes, content}) do
    Enum.filter(content, fn
      {name, attributes, child_content}
      when is_binary(name) and is_list(attributes) and is_list(child_content) ->
        true

      _other ->
        false
    end)
  end
end
