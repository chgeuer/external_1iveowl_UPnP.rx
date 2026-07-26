defmodule UPnP.Eventing.Transport.HTTP do
  @moduledoc """
  GENA transport over the configured `UPnP.HTTP` adapter.

  Initial subscriptions use the application-versioned user agent by default.
  The `:user_agent` transport option overrides it per request; override values
  must be non-empty and must not contain CR or LF characters.
  """

  @behaviour UPnP.Eventing.Transport

  alias UPnP.Eventing.Headers
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.UserAgent

  @impl true
  def subscribe(_state, event_url, callback_url, timeout, options) do
    with {:ok, user_agent} <- UserAgent.from_options(options),
         headers = [
           {"CALLBACK", "<#{URI.to_string(callback_url)}>"},
           {"NT", "upnp:event"},
           {"TIMEOUT", Headers.format_timeout(timeout)},
           {"USER-AGENT", user_agent}
         ],
         {:ok, response} <- request("SUBSCRIBE", event_url, headers, options),
         :ok <- success(response),
         sid when is_binary(sid) and sid != "" <- Response.header(response, "sid") do
      granted =
        case Headers.parse_timeout(Response.header(response, "timeout")) do
          {:ok, value} -> value
          :error -> timeout
        end

      {:ok, %{sid: String.trim(sid), timeout: granted}}
    else
      nil -> {:error, :missing_sid}
      "" -> {:error, :missing_sid}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def renew(_state, event_url, sid, timeout, options) do
    headers = [
      {"SID", sid},
      {"TIMEOUT", Headers.format_timeout(timeout)}
    ]

    with {:ok, response} <- request("SUBSCRIBE", event_url, headers, options),
         :ok <- success(response) do
      case Headers.parse_timeout(Response.header(response, "timeout")) do
        {:ok, value} -> {:ok, value}
        :error -> {:ok, timeout}
      end
    end
  end

  @impl true
  def unsubscribe(_state, event_url, sid, options) do
    with {:ok, response} <- request("UNSUBSCRIBE", event_url, [{"SID", sid}], options),
         :ok <- success(response) do
      :ok
    end
  end

  defp request(method, url, headers, options) do
    adapter = Keyword.fetch!(options, :http_adapter)
    max_body_bytes = Keyword.get(options, :max_body_bytes, 65_536)

    UPnP.HTTP.request(
      adapter,
      %Request{
        method: method,
        url: url,
        headers: headers,
        max_body_bytes: max_body_bytes
      }
    )
  end

  defp success(%Response{status: status}) when status in 200..299, do: :ok

  defp success(%Response{status: status, body: body}),
    do: {:error, {:http_status, status, body}}
end
