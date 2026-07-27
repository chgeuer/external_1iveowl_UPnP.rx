defmodule UPnP.SSDP.Parser do
  @moduledoc false

  alias UPnP.SSDP.Envelope

  # UPnP devices should refresh presence at least daily; never retain a wire value longer.
  @maximum_max_age_seconds 86_400

  @spec parse(binary()) :: {:ok, Envelope.t()} | {:error, :empty | :unsupported_message}
  def parse(datagram) when is_binary(datagram) do
    case String.split(datagram, ~r/\r?\n/, trim: false) do
      [first_line | header_lines] when first_line != "" ->
        with {:ok, kind_hint} <- kind(first_line) do
          {headers, malformed_headers?} = parse_headers(header_lines)
          build(kind_hint, headers, malformed_headers?)
        end

      _ ->
        {:error, :empty}
    end
  end

  defp kind(first_line) do
    normalized = first_line |> String.trim() |> String.upcase()

    cond do
      String.match?(normalized, ~r/^HTTP\/1\.[01]\s+200(?:\s|$)/) ->
        {:ok, :search_response}

      normalized == "NOTIFY * HTTP/1.1" or normalized == "NOTIFY * HTTP/1.0" ->
        {:ok, :notify}

      true ->
        {:error, :unsupported_message}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce(lines, {%{}, false}, fn line, {headers, malformed?} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" ->
          {headers, malformed?}

        true ->
          case String.split(trimmed, ":", parts: 2) do
            [name, value] when name != "" ->
              {Map.put_new(headers, String.downcase(String.trim(name)), String.trim(value)),
               malformed?}

            _ ->
              {headers, true}
          end
      end
    end)
  end

  defp build(kind_hint, headers, malformed_headers?) do
    {kind, kind_error?} = notification_kind(kind_hint, headers["nts"])
    {location, location_error?} = parse_location(headers["location"])
    {boot_id, boot_error?} = parse_non_negative(headers["bootid.upnp.org"])
    {config_id, config_error?} = parse_non_negative(headers["configid.upnp.org"])
    {max_age, cache_error?} = parse_max_age(headers["cache-control"])

    {:ok,
     %Envelope{
       kind: kind,
       headers: headers,
       location: location,
       usn: headers["usn"],
       search_target: headers["st"],
       notification_type: headers["nt"],
       server: headers["server"],
       boot_id: boot_id,
       config_id: config_id,
       max_age: max_age,
       parsing_error?:
         malformed_headers? or kind_error? or location_error? or boot_error? or config_error? or
           cache_error?
     }}
  end

  defp notification_kind(:search_response, _nts), do: {:search_response, false}

  defp notification_kind(:notify, nts) do
    case nts && String.downcase(String.trim(nts)) do
      "ssdp:alive" -> {:alive, false}
      "ssdp:byebye" -> {:byebye, false}
      _ -> {:alive, true}
    end
  end

  defp parse_location(nil), do: {nil, false}

  defp parse_location(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        {uri, false}

      _ ->
        {nil, true}
    end
  end

  defp parse_non_negative(nil), do: {nil, false}

  defp parse_non_negative(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> {number, false}
      _ -> {nil, true}
    end
  end

  defp parse_max_age(nil), do: {nil, false}

  defp parse_max_age(value) do
    with [_, seconds] <- Regex.run(~r/(?:^|,)\s*max-age\s*=\s*"?(\d+)/i, value),
         {number, ""} <- Integer.parse(seconds) do
      {min(number, @maximum_max_age_seconds), false}
    else
      _ -> {nil, true}
    end
  end
end
