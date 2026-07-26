defmodule UPnP.Eventing.Parser do
  @moduledoc "Pure parser for GENA event property-set request bodies."

  alias UPnP.{EventedProperty, ParseError, XML}

  @doc "Parses a GENA property set into evented property values."
  @spec parse(binary()) :: {:ok, [EventedProperty.t()]} | {:error, ParseError.t()}
  def parse(xml) when is_binary(xml) do
    with {:ok, root} <- XML.parse(xml, :gena_property_set),
         {:ok, property_set} <- find_property_set(root) do
      properties =
        property_set
        |> XML.children("property")
        |> Enum.flat_map(&element_children/1)
        |> Enum.map(fn {name, _attributes, _content} = variable ->
          %EventedProperty{
            name: XML.local_name(name),
            value: variable |> XML.text() |> String.trim()
          }
        end)

      {:ok, properties}
    end
  end

  @doc "Alias for `parse/1`."
  @spec parse_property_set(binary()) ::
          {:ok, [EventedProperty.t()]} | {:error, ParseError.t()}
  def parse_property_set(xml), do: parse(xml)

  defp find_property_set(root) do
    case XML.find_first(root, "propertyset") do
      nil ->
        {:error,
         %ParseError{
           source: :gena_property_set,
           message: "NOTIFY body contains no propertyset element",
           reason: :missing_property_set
         }}

      property_set ->
        {:ok, property_set}
    end
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
