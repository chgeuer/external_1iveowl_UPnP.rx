defmodule UPnP.HTTP.Finch do
  @moduledoc """
  Finch-backed raw HTTP transport with a hard response-body limit.
  """

  @behaviour UPnP.HTTP

  alias UPnP.HTTP.{Request, Response}

  @impl true
  def request(%Request{} = request, options) do
    finch = Keyword.get(options, :name, UPnP.Finch)
    url = if match?(%URI{}, request.url), do: URI.to_string(request.url), else: request.url

    finch_request =
      Finch.build(request.method, url, request.headers, request.body)

    finch_options =
      Keyword.take(options, [:pool_timeout, :receive_timeout, :request_timeout, :pool_strategy])
      |> Keyword.put_new(:pool_timeout, :infinity)

    accumulator = %{status: nil, headers: [], body: [], size: 0, too_large?: false}

    stream_result =
      Finch.stream_while(
        finch_request,
        finch,
        accumulator,
        fn
          {:status, status}, accumulator ->
            {:cont, %{accumulator | status: status}}

          {:headers, headers}, accumulator ->
            {:cont, %{accumulator | headers: accumulator.headers ++ headers}}

          {:trailers, trailers}, accumulator ->
            {:cont, %{accumulator | headers: accumulator.headers ++ trailers}}

          {:data, data}, accumulator ->
            size = accumulator.size + byte_size(data)

            if size > request.max_body_bytes do
              {:halt, %{accumulator | size: size, too_large?: true}}
            else
              {:cont, %{accumulator | body: [data | accumulator.body], size: size}}
            end
        end,
        finch_options
      )

    to_response(stream_result, request.max_body_bytes)
  end

  defp to_response({:ok, %{too_large?: true}}, limit), do: {:error, {:body_too_large, limit}}

  defp to_response({:ok, %{status: nil}}, _limit), do: {:error, :malformed_response}

  defp to_response({:ok, accumulator}, _limit) do
    {:ok,
     %Response{
       status: accumulator.status,
       headers: accumulator.headers,
       body: accumulator.body |> Enum.reverse() |> IO.iodata_to_binary()
     }}
  end

  defp to_response({:error, error, _accumulator}, _limit), do: {:error, {:transport, error}}
end
