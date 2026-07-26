defmodule UPnP.SOAP.Parser do
  @moduledoc false

  alias UPnP.{ActionResult, ParseError, UpnpError, XML}

  @spec parse(binary(), binary()) ::
          {:ok, UPnP.SOAP.parsed_response()} | {:error, ParseError.t()}
  def parse(xml, action_name) when is_binary(xml) and is_binary(action_name) do
    with :ok <- validate_action_name(action_name),
         {:ok, root} <- XML.parse(xml, :soap_response) do
      case find_element(root, "Fault") do
        nil ->
          with {:ok, result} <- parse_action_root(root, action_name) do
            {:ok, {:action_result, result}}
          end

        _fault ->
          with {:ok, error} <- parse_fault_root(root) do
            {:ok, {:upnp_error, error}}
          end
      end
    end
  end

  @spec parse_fault(binary()) :: {:ok, UpnpError.t()} | {:error, ParseError.t()}
  def parse_fault(xml) when is_binary(xml) do
    with {:ok, root} <- XML.parse(xml, :soap_fault) do
      parse_fault_root(root)
    end
  end

  defp parse_action_root(root, action_name) do
    expected_name = action_name <> "Response"
    elements = [root | XML.descendants(root)]

    response =
      Enum.find(elements, fn {name, _attributes, _content} ->
        XML.name?(name, expected_name)
      end) ||
        Enum.find(elements, fn {name, _attributes, _content} ->
          name
          |> XML.local_name()
          |> String.downcase()
          |> String.ends_with?("response")
        end)

    case response do
      nil ->
        parse_error(
          "SOAP document contains no #{expected_name} element",
          :missing_action_response
        )

      {_name, _attributes, content} ->
        {:ok, %ActionResult{out: collect_output_arguments(content)}}
    end
  end

  defp collect_output_arguments(content) do
    content
    |> Enum.reduce({%{}, MapSet.new()}, fn
      {name, attributes, child_content} = element, {out, seen}
      when is_binary(name) and is_list(attributes) and is_list(child_content) ->
        local_name = XML.local_name(name)
        folded_name = String.downcase(local_name)

        if local_name == "" or MapSet.member?(seen, folded_name) do
          {out, seen}
        else
          {Map.put(out, local_name, element |> XML.text() |> String.trim()),
           MapSet.put(seen, folded_name)}
        end

      _other, accumulator ->
        accumulator
    end)
    |> elem(0)
  end

  defp parse_fault_root(root) do
    case find_element(root, "Fault") do
      nil ->
        parse_error("SOAP document contains no Fault element", :missing_fault)

      _fault ->
        parse_upnp_error(root)
    end
  end

  defp parse_upnp_error(root) do
    case find_element(root, "UPnPError") do
      nil ->
        parse_error("SOAP Fault contains no UPnPError element", :missing_upnp_error)

      upnp_error ->
        case descendant_integer(upnp_error, "errorCode") do
          code when is_integer(code) and code >= 0 ->
            {:ok,
             %UpnpError{
               code: code,
               description:
                 upnp_error
                 |> find_element("errorDescription")
                 |> XML.text_or_nil()
             }}

          _other ->
            parse_error(
              "SOAP UPnPError contains no parsable errorCode",
              :missing_error_code
            )
        end
    end
  end

  defp validate_action_name(action_name) do
    if String.valid?(action_name) and String.trim(action_name) != "" do
      :ok
    else
      parse_error("action name must be a non-empty UTF-8 binary", :invalid_action_name)
    end
  end

  defp descendant_integer(element, expected) do
    case find_element(element, expected) do
      nil ->
        nil

      match ->
        case match |> XML.text() |> String.trim() |> Integer.parse() do
          {integer, ""} -> integer
          _other -> nil
        end
    end
  end

  defp find_element(root, expected), do: XML.find_first(root, expected)

  defp parse_error(message, reason) do
    {:error, %ParseError{source: :soap_response, message: message, reason: reason}}
  end
end
