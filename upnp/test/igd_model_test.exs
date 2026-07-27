defmodule UPnP.IGDModelTest do
  use ExUnit.Case, async: true

  alias UPnP.IGD.{Lease, Mapping, Protocol, Status}
  alias UPnP.Subscription

  test "protocol values have strict output and lenient input" do
    assert Protocol.to_wire(:tcp) == "TCP"
    assert Protocol.to_wire(:udp) == "UDP"
    assert Protocol.parse(" udp ") == {:ok, :udp}
    assert Protocol.parse("sctp") == {:error, :invalid_protocol}
  end

  test "status treats missing and non-connected values as disconnected" do
    refute Status.connected?(%Status{})
    refute Status.connected?(%Status{status: " Disconnected "})
  end

  test "lease and subscription shutdown stay idempotent after their owner exits" do
    dead = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = Process.monitor(dead)
    send(dead, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}

    mapping = %Mapping{
      external_port: 4_000,
      internal_port: 4_000,
      protocol: :tcp,
      internal_client: "192.0.2.10"
    }

    lease = %Lease{server: dead, mapping: mapping}
    assert Lease.close(lease) == :ok
    assert Lease.abandon(lease) == :ok

    subscription = %Subscription{server: dead, ref: make_ref(), kind: :test}
    assert Subscription.close(subscription) == :ok
  end

  test "subscription close stays idempotent when its owner exits arbitrarily" do
    test = self()
    ref = make_ref()

    server =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:unsubscribe, ^ref}} ->
            send(test, {:unsubscribe_started, self()})
            receive do: (:continue -> :ok)
        end
      end)

    subscription = %Subscription{server: server, ref: ref, kind: :test}

    caller =
      spawn(fn ->
        send(test, {:subscription_close_result, self(), Subscription.close(subscription)})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:unsubscribe_started, ^server}
    Process.exit(server, :boom)

    assert_receive {:subscription_close_result, ^caller, :ok}
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
  end

  test "device identity and action lookup tolerate absent and foreign entries" do
    location = URI.parse("http://192.0.2.1/device.xml")
    assert UPnP.Device.identity(%UPnP.Device{location: location}) == URI.to_string(location)

    result = %UPnP.ActionResult{out: %{42 => "ignored", "Value" => "kept"}}
    assert UPnP.ActionResult.get(result, "value") == "kept"
    assert UPnP.ActionResult.get(result, <<0xFF>>) == nil
  end
end
