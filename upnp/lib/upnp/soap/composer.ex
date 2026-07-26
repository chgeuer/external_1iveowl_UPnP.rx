defmodule UPnP.SOAP.Composer do
  @moduledoc false

  alias UPnP.ParseError

  @soap_envelope "http://schemas.xmlsoap.org/soap/envelope/"
  @soap_encoding "http://schemas.xmlsoap.org/soap/encoding/"
  @xml_name ~r/^[A-Za-z_][A-Za-z0-9_.-]*$/

  @spec compose(binary(), binary(), UPnP.SOAP.arguments()) ::
          {:ok, binary()} | {:error, ParseError.t()}
  def compose(service_type, action_name, arguments)
      when is_binary(service_type) and is_binary(action_name) do
    with :ok <- validate_service_type(service_type),
         :ok <- validate_xml_name(action_name, :action_name),
         {:ok, pairs} <- normalize_arguments(arguments),
         :ok <- validate_arguments(pairs) do
      action =
        {"u:" <> action_name, [{"xmlns:u", service_type}],
         Enum.map(pairs, fn {name, value} ->
           {name, [], [{:characters, value}]}
         end)}

      envelope =
        {"s:Envelope",
         [
           {"xmlns:s", @soap_envelope},
           {"s:encodingStyle", @soap_encoding}
         ], [{"s:Body", [], [action]}]}

      try do
        body = Saxy.encode!(envelope)
        {:ok, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" <> body}
      rescue
        error ->
          parse_error(
            "could not encode the SOAP request",
            {:encoder_error, error}
          )
      end
    end
  end

  @spec soap_action_header(binary(), binary()) ::
          {:ok, binary()} | {:error, ParseError.t()}
  def soap_action_header(service_type, action_name)
      when is_binary(service_type) and is_binary(action_name) do
    with :ok <- validate_service_type(service_type),
         :ok <- validate_xml_name(action_name, :action_name) do
      {:ok, "\"#{service_type}##{action_name}\""}
    end
  end

  defp validate_service_type(service_type) do
    cond do
      not String.valid?(service_type) ->
        parse_error("service type is not valid UTF-8", :invalid_service_type)

      not valid_xml_characters?(service_type) ->
        parse_error(
          "service type contains a character XML 1.0 cannot encode",
          :invalid_service_type
        )

      service_type == "" or service_type != String.trim(service_type) ->
        parse_error("service type must not be empty or padded", :invalid_service_type)

      String.contains?(service_type, ["\"", "\r", "\n"]) ->
        parse_error("service type contains an unsafe header character", :invalid_service_type)

      true ->
        :ok
    end
  end

  defp validate_xml_name(name, field) do
    if String.valid?(name) and Regex.match?(@xml_name, name) do
      :ok
    else
      parse_error("#{field} is not a valid unqualified XML name", {:invalid_xml_name, field})
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) and not is_struct(arguments) do
    {:ok, Map.to_list(arguments)}
  end

  defp normalize_arguments(arguments) when is_list(arguments) do
    if Enum.all?(arguments, &match?({_, _}, &1)) do
      {:ok, arguments}
    else
      parse_error("arguments must be name/value pairs", :invalid_arguments)
    end
  end

  defp normalize_arguments(_arguments) do
    parse_error("arguments must be an ordered pair list or map", :invalid_arguments)
  end

  defp validate_arguments(pairs) do
    Enum.reduce_while(pairs, {:ok, MapSet.new()}, fn
      {name, value}, {:ok, seen} when is_binary(name) and is_binary(value) ->
        with :ok <- validate_xml_name(name, :argument_name),
             :ok <- validate_argument_value(name, value) do
          folded_name = String.downcase(name)

          if MapSet.member?(seen, folded_name) do
            {:halt,
             parse_error(
               "SOAP argument names must be unique",
               {:duplicate_argument, name}
             )}
          else
            {:cont, {:ok, MapSet.put(seen, folded_name)}}
          end
        else
          {:error, _error} = failure -> {:halt, failure}
        end

      _pair, _accumulator ->
        {:halt,
         parse_error(
           "SOAP argument names and values must be binaries",
           :invalid_arguments
         )}
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _error} = failure -> failure
    end
  end

  defp validate_argument_value(name, value) do
    cond do
      not String.valid?(value) ->
        parse_error(
          "SOAP argument #{inspect(name)} is not valid UTF-8",
          :invalid_argument_value
        )

      not valid_xml_characters?(value) ->
        parse_error(
          "SOAP argument #{inspect(name)} contains a character XML 1.0 cannot encode",
          :invalid_argument_value
        )

      true ->
        :ok
    end
  end

  defp valid_xml_characters?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(fn codepoint ->
      codepoint in [0x9, 0xA, 0xD] or
        codepoint in 0x20..0xD7FF or
        codepoint in 0xE000..0xFFFD or
        codepoint in 0x10000..0x10FFFF
    end)
  end

  defp parse_error(message, reason) do
    {:error, %ParseError{source: :soap_request, message: message, reason: reason}}
  end
end
