defmodule UPnP.OptionsTest do
  use ExUnit.Case, async: true

  alias UPnP.Options
  alias UPnP.SSDP.SearchTarget

  test "provides protocol-safe defaults" do
    assert {:ok, options} = Options.new([])
    assert options.default_search_target == SearchTarget.root_device()
    assert options.default_mx == 3
    assert options.action_timeout == 30_000
    assert options.event_subscription_timeout == 1_800_000
    assert options.roster_expiry_fallback == 1_800_000
    assert options.network_adapter == UPnP.Network.System
  end

  test "rejects unknown and header-injecting options" do
    assert {:error, {:unknown_options, [:surprise]}} = Options.new(surprise: true)

    assert {:error, :invalid_friendly_name} =
             Options.new(friendly_name: "friendly\r\nX-Evil: yes")
  end

  test "validates interfaces and M-SEARCH MX" do
    assert {:error, :invalid_interfaces} = Options.new(interfaces: [{999, 0, 0, 1}])
    assert {:error, :invalid_default_mx} = Options.new(default_mx: 6)
  end

  test "validates and carries a network Adapter with its state" do
    adapter = {UPnP.Network.System, route_state: :test}

    assert {:ok, options} = Options.new(network_adapter: adapter)
    assert options.network_adapter == adapter
    assert {:error, :invalid_network_adapter} = Options.new(network_adapter: "invalid")
  end

  test "validates callback routing and retry bounds" do
    assert {:error, :invalid_event_callback_bind} =
             Options.new(event_callback_bind: :invalid)

    assert {:error, :invalid_event_callback_base_url} =
             Options.new(event_callback_base_url: "/relative")

    assert {:error, :invalid_event_retry_backoff} =
             Options.new(event_retry_backoff: [100, -1])

    assert {:ok, options} =
             Options.new(
               event_callback_bind: {0, 0, 0, 0},
               event_callback_base_url: "http://192.0.2.20:4001",
               event_retry_backoff: [100, 500]
             )

    assert options.event_retry_backoff == [100, 500]
  end
end
