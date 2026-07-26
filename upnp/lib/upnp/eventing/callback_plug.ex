defmodule UPnP.Eventing.CallbackPlug do
  @moduledoc """
  The private Plug endpoint used for unicast GENA callbacks.

  Routes contain both a manager token and a per-subscription token. Requests
  for every other path are rejected and are never forwarded.
  """

  @behaviour Plug

  import Plug.Conn

  alias UPnP.Eventing.{Headers, Manager}

  @impl Plug
  @doc "Initializes callback routing and request-size limits."
  @spec init(keyword()) :: map()
  def init(options) do
    %{
      manager: Keyword.fetch!(options, :manager),
      manager_token: Keyword.fetch!(options, :manager_token),
      path_prefix: Keyword.get(options, :path_prefix, ["upnp", "events"]),
      max_body_bytes: Keyword.get(options, :max_body_bytes, 1_048_576)
    }
  end

  @impl Plug
  @doc "Validates and dispatches one callback HTTP request."
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, options) do
    with {:ok, token} <- route_token(conn.path_info, options),
         :ok <- known_route(options.manager, token),
         :ok <- notify_method(conn),
         {:ok, sid, sequence} <- gena_headers(conn),
         :ok <- content_length(conn, options.max_body_bytes),
         :ok <- content_type(conn),
         {:ok, body, conn} <- read_bounded(conn, options.max_body_bytes),
         :ok <- deliver(options.manager, token, sid, sequence, body) do
      send_resp(conn, 200, "")
    else
      {:error, status, conn} -> respond(conn, status)
      {:error, status} -> respond(conn, status)
    end
  end

  defp route_token(path_info, options) do
    prefix = options.path_prefix
    prefix_length = length(prefix)

    case Enum.split(path_info, prefix_length) do
      {^prefix, [manager_token, subscription_token]}
      when manager_token != "" and subscription_token != "" ->
        if Plug.Crypto.secure_compare(manager_token, options.manager_token) do
          {:ok, subscription_token}
        else
          {:error, 404}
        end

      _other ->
        {:error, 404}
    end
  end

  defp known_route(manager, token) do
    case safe_call(fn -> Manager.known_callback?(manager, token) end) do
      true -> :ok
      false -> {:error, 404}
      {:error, :unavailable} -> {:error, 503}
    end
  end

  defp notify_method(%Plug.Conn{method: method}) do
    if String.upcase(method) == "NOTIFY", do: :ok, else: {:error, 405}
  end

  defp gena_headers(conn) do
    with {:ok, nt} <- required_header(conn, "nt", 400),
         {:ok, nts} <- required_header(conn, "nts", 400),
         :ok <- expected_header(nt, "upnp:event"),
         :ok <- expected_header(nts, "upnp:propchange"),
         {:ok, sid} <- required_header(conn, "sid", 412),
         {:ok, raw_sequence} <- required_header(conn, "seq", 400),
         {:ok, sequence} <- parse_sequence(raw_sequence) do
      {:ok, sid, sequence}
    end
  end

  defp required_header(conn, name, missing_status) do
    case get_req_header(conn, name) do
      [value] ->
        case String.trim(value) do
          "" -> {:error, missing_status}
          trimmed -> {:ok, trimmed}
        end

      [] ->
        {:error, missing_status}

      _duplicates ->
        {:error, 400}
    end
  end

  defp expected_header(actual, expected) do
    if String.downcase(actual) == expected, do: :ok, else: {:error, 412}
  end

  defp parse_sequence(raw_sequence) do
    case Headers.parse_seq(raw_sequence) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> {:error, 400}
    end
  end

  defp content_length(conn, maximum) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(String.trim(value)) do
          {length, ""} when length >= 0 and length <= maximum -> :ok
          {length, ""} when length > maximum -> {:error, 413}
          _other -> {:error, 400}
        end

      _duplicates ->
        {:error, 400}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        media_type =
          value
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()

        if media_type in ["text/xml", "application/xml"] or String.ends_with?(media_type, "+xml") do
          :ok
        else
          {:error, 415}
        end

      [] ->
        {:error, 415}

      _duplicates ->
        {:error, 400}
    end
  end

  defp read_bounded(conn, maximum), do: read_bounded(conn, maximum, [], 0)

  defp read_bounded(conn, maximum, chunks, size) do
    case read_body(conn, length: maximum + 1, read_length: min(maximum + 1, 64_000)) do
      {:ok, chunk, conn} ->
        finish_body(conn, chunks, size, chunk, maximum)

      {:more, chunk, conn} ->
        new_size = size + byte_size(chunk)

        if new_size > maximum do
          {:error, 413, conn}
        else
          read_bounded(conn, maximum, [chunk | chunks], new_size)
        end

      {:error, _reason} ->
        {:error, 400, conn}
    end
  end

  defp finish_body(conn, chunks, size, chunk, maximum) do
    if size + byte_size(chunk) > maximum do
      {:error, 413, conn}
    else
      {:ok, chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary(), conn}
    end
  end

  defp deliver(manager, token, sid, sequence, body) do
    case safe_call(fn -> Manager.deliver_callback(manager, token, sid, sequence, body) end) do
      :ok -> :ok
      {:error, status} when is_integer(status) -> {:error, status}
      {:error, :unavailable} -> {:error, 503}
    end
  end

  defp safe_call(function) do
    function.()
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp respond(conn, 405) do
    conn
    |> put_resp_header("allow", "NOTIFY")
    |> send_resp(405, "")
  end

  defp respond(conn, status), do: send_resp(conn, status, "")
end
