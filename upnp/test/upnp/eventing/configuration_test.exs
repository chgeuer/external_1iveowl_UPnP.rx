defmodule UPnP.Eventing.ConfigurationTest do
  use ExUnit.Case, async: true

  alias UPnP.Eventing.Configuration

  @event_url URI.parse("http://device:1400/events")
  @required_options [
    task_supervisor: :tasks,
    subscription_supervisor: :subscriptions,
    server_supervisor: :servers
  ]

  defmodule FakeNetwork do
    @behaviour UPnP.Network

    @impl true
    def local_address_for(uri, {test, result}) do
      send(test, {:route_requested, uri})
      result
    end
  end

  test "composes callback origins and token URLs from canonical base configuration" do
    config =
      configuration(
        callback_base_url: "HTTPS://Callback.Example:444/custom/events?discard=yes#discard"
      )

    assert {:ok, origin} = Configuration.callback_origin(config, @event_url, 4_001, [])
    assert origin.scheme == "https"
    assert origin.host == "callback.example"
    assert origin.port == 444

    callback =
      Configuration.callback_url(config, origin, "manager-token", "callback-token")

    assert URI.to_string(callback) ==
             "https://callback.example:444/custom/events/manager-token/callback-token"

    assert callback.query == nil
    assert callback.fragment == nil
    assert callback.userinfo == nil
  end

  test "routes callback origins through the configured network Adapter" do
    config =
      configuration(
        callback_bind: :any,
        network_adapter: {FakeNetwork, {self(), {:ok, {192, 0, 2, 25}}}}
      )

    assert {:ok, %URI{scheme: "http", host: "192.0.2.25", port: 4_001}} =
             Configuration.callback_origin(config, @event_url, 4_001, [])

    assert_receive {:route_requested, @event_url}
  end

  test "rejects invalid configuration and noncanonical subscription aliases" do
    assert {:error, :invalid_callback_base_url} =
             Configuration.new(@required_options ++ [callback_base_url: "/relative"])

    config = configuration()

    assert {:error, {:unknown_options, [:callback_base_url]}} =
             Configuration.callback_origin(
               config,
               @event_url,
               4_001,
               callback_base_url: "http://192.0.2.10:4000"
             )
  end

  defp configuration(options \\ []) do
    assert {:ok, config} = Configuration.new(Keyword.merge(@required_options, options))
    config
  end
end
