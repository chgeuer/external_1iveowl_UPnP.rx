defmodule UPnP.Action do
  @moduledoc false

  alias UPnP.HTTP
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.SOAP.{Composer, Parser}

  @spec invoke(
          UPnP.ServiceDescription.t(),
          binary(),
          Composer.arguments(),
          UPnP.Options.t(),
          keyword()
        ) :: {:ok, UPnP.ActionResult.t()} | {:error, term()}
  def invoke(service, action_name, arguments, control_point_options, options) do
    timeout = Keyword.get(options, :timeout, control_point_options.action_timeout)

    result =
      cond do
        not match?(%URI{}, service.control_url) ->
          {:error, :missing_control_url}

        not is_integer(timeout) or timeout <= 0 ->
          {:error, :invalid_timeout}

        true ->
          do_invoke(service, action_name, arguments, control_point_options, timeout)
      end

    :telemetry.execute([:upnp, :action, :invoke], %{count: 1}, %{
      service_type: service.service_type,
      action: action_name,
      outcome: outcome(result)
    })

    result
  end

  defp do_invoke(service, action_name, arguments, options, timeout) do
    with {:ok, body} <- Composer.compose(service.service_type, action_name, arguments),
         {:ok, soap_action} <- Composer.soap_action_header(service.service_type, action_name),
         {:ok, response} <-
           HTTP.request_with_deadline(
             options.http_adapter,
             %Request{
               method: "POST",
               url: service.control_url,
               headers: [
                 {"CONTENT-TYPE", ~s(text/xml; charset="utf-8")},
                 {"SOAPACTION", soap_action},
                 {"USER-AGENT", user_agent()}
               ],
               body: body,
               max_body_bytes: options.max_document_bytes
             },
             timeout: timeout,
             clock: options.clock
           ) do
      parse_response(response, action_name)
    end
  end

  defp parse_response(%Response{status: status, body: body}, action_name) do
    case Parser.parse(body, action_name) do
      {:ok, {:action_result, result}} when status in 200..299 ->
        {:ok, result}

      {:ok, {:action_result, _result}} ->
        {:error, {:http_status, status, body}}

      {:ok, {:upnp_error, error}} ->
        {:error, {:upnp_error, error}}

      {:error, parse_error} when status in 200..299 ->
        {:error, {:parse, parse_error}}

      {:error, parse_error} ->
        {:error, {:http_status, status, parse_error}}
    end
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, {:upnp_error, error}}), do: {:upnp_error, error.code}
  defp outcome({:error, reason}), do: {:error, UPnP.Telemetry.classify_error(reason)}

  defp user_agent, do: "Elixir/#{System.version()} UPnP/2.0 upnp/0.1"
end
