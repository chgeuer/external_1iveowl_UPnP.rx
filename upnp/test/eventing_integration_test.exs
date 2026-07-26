defmodule UPnP.EventingIntegrationTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.Eventing.{Lifecycle, Manager}
  alias UPnP.{ControlPoint, Service, ServiceDescription}

  @async_timeout 1_000

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

    task_supervisor = start_supervised!(Task.Supervisor)

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

    %{
      clock: clock,
      control_point: control_point,
      service: service,
      task_supervisor: task_supervisor
    }
  end

  test "service subscriptions use the control point manager and close gracefully", %{
    control_point: control_point,
    service: service,
    task_supervisor: task_supervisor
  } do
    subscriber = self()

    subscribing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Service.subscribe(service, subscriber: subscriber)
      end)

    assert_receive {:eventing_transport, worker,
                    {:subscribe, event_url, callback_url, 4_000, _options}},
                   @async_timeout

    assert URI.to_string(event_url) == "http://127.0.0.1:1400/events"
    assert callback_url.host == "127.0.0.1"
    send(worker, {:eventing_transport_reply, {:ok, %{sid: "uuid:integrated", timeout: 4_000}}})

    assert {:ok, subscription, []} = Task.await(subscribing, @async_timeout)
    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed}}, @async_timeout
    assert ref == subscription.ref

    assert {:ok, %{port: port, path: "/upnp/events"}} =
             ControlPoint.event_callback_info(control_point)

    assert port > 0
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    assert Manager.subscription_pid(manager, event_url) != nil

    control_point_monitor = Process.monitor(control_point)

    closing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ControlPoint.close(control_point)
      end)

    assert_receive {:eventing_transport, goodbye,
                    {:unsubscribe, ^event_url, "uuid:integrated", _options}},
                   @async_timeout

    send(goodbye, {:eventing_transport_reply, :ok})
    assert :ok = Task.await(closing, @async_timeout)

    assert_receive {:DOWN, ^control_point_monitor, :process, ^control_point, :normal},
                   @async_timeout

    refute Process.alive?(control_point)
  end

  test "an aborted subscription caller cannot leave its eventing worker behind", %{
    clock: clock,
    control_point: control_point,
    service: service,
    task_supervisor: task_supervisor
  } do
    subscriber = self()

    subscribing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Service.subscribe(service, subscriber: subscriber)
      end)

    assert_receive {:eventing_transport, operation,
                    {:subscribe, event_url, _callback_url, 4_000, _options}},
                   @async_timeout

    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    subscription_worker = Manager.subscription_pid(manager, event_url)
    assert is_pid(subscription_worker)
    worker_monitor = Process.monitor(subscription_worker)
    caller_monitor = Process.monitor(subscribing.pid)

    assert :ok = stop_supervised(Task.Supervisor)

    assert_receive {:DOWN, ^caller_monitor, :process, _caller, :shutdown}, @async_timeout

    send(operation, {:eventing_transport_reply, {:ok, %{sid: "uuid:orphan", timeout: 4_000}}})

    assert_receive {:eventing_transport, goodbye,
                    {:unsubscribe, ^event_url, "uuid:orphan", _options}},
                   @async_timeout

    send(goodbye, {:eventing_transport_reply, :ok})

    assert_receive {:DOWN, ^worker_monitor, :process, ^subscription_worker, :normal},
                   @async_timeout

    assert Manager.subscription_pid(manager, event_url) == nil

    control_point_monitor = Process.monitor(control_point)
    assert :ok = ControlPoint.close(control_point)

    assert_receive {:DOWN, ^control_point_monitor, :process, ^control_point, :normal},
                   @async_timeout

    assert Process.alive?(clock)
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
