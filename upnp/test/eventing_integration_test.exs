defmodule UPnP.EventingIntegrationTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.Eventing.{Lifecycle, Manager}
  alias UPnP.{ControlPoint, Service, ServiceDescription}

  defmodule FakeTransport do
    @behaviour UPnP.Eventing.Transport

    @impl true
    def subscribe(test, event_url, callback_url, timeout, options) do
      request(test, {:subscribe, event_url, callback_url, timeout, options})
    end

    @impl true
    def renew(test, event_url, sid, timeout, options) do
      request(test, {:renew, event_url, sid, timeout, options})
    end

    @impl true
    def unsubscribe(test, event_url, sid, options) do
      request(test, {:unsubscribe, event_url, sid, options})
    end

    defp request(test, request) do
      send(test, {:eventing_transport, self(), request})

      receive do
        {:eventing_transport_reply, result} -> result
      end
    end
  end

  setup do
    {:ok, clock} = start_supervised(Manual)

    {:ok, control_point} =
      start_supervised(
        {ControlPoint,
         interfaces: [],
         clock: {Manual, clock},
         event_transport: {FakeTransport, self()},
         event_callback_bind: {127, 0, 0, 1},
         event_subscription_timeout: 4_000}
      )

    service =
      Service.new(
        control_point,
        %ServiceDescription{
          service_type: "urn:schemas-upnp-org:service:RenderingControl:1",
          event_sub_url: URI.parse("http://127.0.0.1:1400/events")
        },
        {:test, 1},
        {127, 0, 0, 1}
      )

    %{control_point: control_point, service: service}
  end

  test "service subscriptions use the control point manager and close gracefully", %{
    control_point: control_point,
    service: service
  } do
    subscriber = self()
    subscribing = Task.async(fn -> Service.subscribe(service, subscriber: subscriber) end)

    assert_receive {:eventing_transport, worker,
                    {:subscribe, event_url, callback_url, 4_000, _options}}

    assert URI.to_string(event_url) == "http://127.0.0.1:1400/events"
    assert callback_url.host == "127.0.0.1"
    send(worker, {:eventing_transport_reply, {:ok, %{sid: "uuid:integrated", timeout: 4_000}}})

    assert {:ok, subscription, []} = Task.await(subscribing)
    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed}}
    assert ref == subscription.ref

    assert {:ok, %{port: port, path: "/upnp/events"}} =
             ControlPoint.event_callback_info(control_point)

    assert port > 0
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    assert Manager.subscription_pid(manager, event_url) != nil

    control_point_monitor = Process.monitor(control_point)
    closing = Task.async(fn -> ControlPoint.close(control_point) end)

    assert_receive {:eventing_transport, goodbye,
                    {:unsubscribe, ^event_url, "uuid:integrated", _options}}

    send(goodbye, {:eventing_transport_reply, :ok})
    assert :ok = Task.await(closing)
    assert_receive {:DOWN, ^control_point_monitor, :process, ^control_point, :normal}
    refute Process.alive?(control_point)
  end

  test "services without an event URL return tagged data", %{control_point: control_point} do
    service =
      Service.new(
        control_point,
        %ServiceDescription{service_type: "urn:example"},
        :test
      )

    assert Service.subscribe(service) == {:error, :missing_event_sub_url}
  end
end
