defmodule UPnP.OptionsTest do
  use ExUnit.Case, async: true

  alias UPnP.Options
  alias UPnP.SSDP.SearchTarget

  test "provides protocol-safe defaults" do
    assert {:ok, options} = Options.new([])
    assert {:ok, ^options} = Options.new(options)
    assert options.default_search_target == SearchTarget.root_device()
    assert options.default_mx == 3
    assert options.action_timeout == 30_000
    assert options.event_subscription_timeout == 1_800_000
    assert options.roster_expiry_fallback == 1_800_000
    assert Map.fetch!(options, :max_roster_entries) == 1_024
    assert options.network_adapter == UPnP.Network.System
  end

  test "rejects unknown and header-injecting options" do
    assert {:error, {:unknown_options, [:surprise]}} = Options.new(surprise: true)

    assert {:error, :invalid_friendly_name} =
             Options.new(friendly_name: "friendly\r\nX-Evil: yes")
  end

  test "validates interfaces and M-SEARCH MX" do
    assert {:error, :invalid_interfaces} = Options.new(interfaces: [{999, 0, 0, 1}])
    assert {:error, :invalid_interfaces} = Options.new(interfaces: :invalid)
    assert {:error, :invalid_interfaces} = Options.new(interfaces: [:invalid])
    assert {:error, :invalid_default_mx} = Options.new(default_mx: 6)
  end

  test "validates the presence roster bound" do
    assert {:ok, options} = Options.new(max_roster_entries: 8)
    assert Map.fetch!(options, :max_roster_entries) == 8
    assert {:error, :invalid_max_roster_entries} = Options.new(max_roster_entries: 0)
    assert {:error, :invalid_max_roster_entries} = Options.new(max_roster_entries: -1)
    assert {:error, :invalid_max_roster_entries} = Options.new(max_roster_entries: "8")
  end

  test "accepts OTP supervisor references and rejects other terms" do
    references = [
      self(),
      {:via, Registry, {:upnp_test, make_ref()}},
      {:global, {:upnp_test, make_ref()}},
      {:upnp_test, node()}
    ]

    Enum.each(references, fn reference ->
      assert {:ok, options} = Options.new(task_supervisor: reference)
      assert options.task_supervisor == reference
    end)

    assert {:error, :invalid_task_supervisor} = Options.new(task_supervisor: "tasks")
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

    assert {:error, :invalid_event_retry_backoff} =
             Options.new(event_retry_backoff: :invalid)

    assert {:error, :invalid_event_callback_host} =
             Options.new(event_callback_host: :invalid)

    assert {:error, :invalid_event_callback_host} =
             Options.new(event_callback_host: "")

    assert {:error, :invalid_event_callback_host} =
             Options.new(event_callback_host: {999, 0, 0, 1})

    assert {:error, :invalid_event_callback_base_url} =
             Options.new(event_callback_base_url: 42)

    assert {:ok, options} =
             Options.new(
               event_callback_bind: {0, 0, 0, 0},
               event_callback_host: {192, 0, 2, 20},
               event_callback_base_url: "http://192.0.2.20:4001",
               event_retry_backoff: [100, 500]
             )

    assert options.event_retry_backoff == [100, 500]
  end
end
