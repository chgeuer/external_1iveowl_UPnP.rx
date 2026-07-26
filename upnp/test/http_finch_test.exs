defmodule UPnP.HTTPFinchTest do
  use ExUnit.Case, async: true

  alias UPnP.HTTP
  alias UPnP.HTTP.{Request, Response}

  defmodule TestPlug do
    import Plug.Conn

    def init(options), do: options

    def call(conn, _options) do
      case conn.request_path do
        "/large" -> send_resp(conn, 200, String.duplicate("x", 128))
        _ -> send_resp(conn, 200, conn.method)
      end
    end
  end

  setup do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: TestPlug,
         port: 0,
         startup_log: false,
         http_2_options: [enabled: false],
         thousand_island_options: [num_acceptors: 1]}
      )

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{base_url: "http://127.0.0.1:#{port}"}
  end

  test "sends arbitrary UPnP HTTP methods without rewriting", %{base_url: base_url} do
    request = %Request{method: "SUBSCRIBE", url: base_url <> "/events"}

    assert {:ok, %Response{status: 200, body: "SUBSCRIBE"}} =
             HTTP.request(UPnP.HTTP.Finch, request)
  end

  test "halts responses over the configured body limit", %{base_url: base_url} do
    request = %Request{
      method: "GET",
      url: base_url <> "/large",
      max_body_bytes: 32
    }

    assert {:error, {:body_too_large, 32}} =
             HTTP.request(UPnP.HTTP.Finch, request)
  end

  test "returns loopback transport failures as tagged data" do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    request = %Request{method: "GET", url: "http://127.0.0.1:#{port}/closed"}
    assert {:error, {:transport, _reason}} = HTTP.request(UPnP.HTTP.Finch, request)
  end
end
