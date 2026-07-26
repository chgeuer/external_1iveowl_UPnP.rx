defmodule UPnP.SCPD.Client do
  @moduledoc false

  alias UPnP.HTTP
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.SCPD.Parser

  @spec fetch(URI.t(), UPnP.Options.t()) :: {:ok, UPnP.SCPD.t()} | {:error, term()}
  def fetch(%URI{} = location, options) do
    request = %Request{
      method: "GET",
      url: location,
      headers: [
        {"ACCEPT", "text/xml, application/xml"},
        {"USER-AGENT", user_agent()}
      ],
      max_body_bytes: options.max_document_bytes
    }

    with {:ok, response} <-
           HTTP.request_with_deadline(options.http_adapter, request,
             timeout: options.description_timeout,
             clock: options.clock
           ),
         {:ok, body} <- successful_body(response),
         {:ok, scpd} <- Parser.parse(body) do
      {:ok, scpd}
    end
  end

  defp successful_body(%Response{status: status, body: body}) when status in 200..299,
    do: {:ok, body}

  defp successful_body(%Response{status: status, body: body}),
    do: {:error, {:http_status, status, body}}

  defp user_agent, do: "Elixir/#{System.version()} UPnP/2.0 upnp/0.1"
end
