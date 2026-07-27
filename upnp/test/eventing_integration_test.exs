defmodule UPnP.EventingIntegrationTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.ControlPoint.Runtime
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

  defmodule FakeNetwork do
    @behaviour UPnP.Network

    @impl true
    def local_address_for(uri, {test, result}) do
      send(test, {:route_requested, uri, result})
      result
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
         network_adapter: {FakeNetwork, {self(), {:ok, {192, 0, 2, 25}}}},
         event_callback_bind: :any,
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
        {172, 17, 0, 1}
      )

    %{
      clock: clock,
      control_point: control_point,
      service: service,
      task_supervisor: task_supervisor
    }
  end

  test "service subscriptions route callbacks independently of the discovery socket", %{
    control_point: control_point,
    service: service,
    task_supervisor: task_supervisor
  } do
    subscriber = self()

    subscribing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Service.subscribe(service, subscriber: subscriber)
      end)

    assert_receive {:route_requested, %URI{host: "127.0.0.1", port: 1400, path: "/events"},
                    {:ok, {192, 0, 2, 25}}},
                   @async_timeout

    assert_receive {:eventing_transport, worker,
                    {:subscribe, event_url, callback_url, 4_000, _options}},
                   @async_timeout

    {runtime_id, :owner} = Runtime.identity(ControlPoint.runtime(control_point))
    runtime_tasks = Runtime.whereis(runtime_id, :tasks)
    assert worker in Task.Supervisor.children(runtime_tasks)
    assert URI.to_string(event_url) == "http://127.0.0.1:1400/events"
    assert callback_url.host == "192.0.2.25"
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

    assert_receive {:upnp, ^ref,
                    %Lifecycle{
                      kind: :lost,
                      reason: {:control_point, :graceful_close}
                    }},
                   @async_timeout

    assert_receive {:eventing_transport, goodbye,
                    {:unsubscribe, ^event_url, "uuid:integrated", _options}},
                   @async_timeout

    assert goodbye in Task.Supervisor.children(runtime_tasks)
    send(goodbye, {:eventing_transport_reply, :ok})
    assert :ok = Task.await(closing, @async_timeout)

    assert_receive {:DOWN, ^control_point_monitor, :process, ^control_point, :shutdown},
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

    assert_receive {:DOWN, ^control_point_monitor, :process, ^control_point, :shutdown},
                   @async_timeout

    assert Process.alive?(clock)
  end

  test "an internal control-point restart terminates GENA consumers with a typed reason", %{
    control_point: control_point,
    service: service,
    task_supervisor: task_supervisor
  } do
    subscriber = self()

    subscribing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Service.subscribe(service, subscriber: subscriber)
      end)

    assert_receive {:route_requested, _event_url, {:ok, {192, 0, 2, 25}}}, @async_timeout

    assert_receive {:eventing_transport, operation,
                    {:subscribe, _event_url, _callback_url, 4_000, _options}},
                   @async_timeout

    send(operation, {
      :eventing_transport_reply,
      {:ok, %{sid: "uuid:restart", timeout: 4_000}}
    })

    assert {:ok, subscription, []} = Task.await(subscribing, @async_timeout)
    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed}}, @async_timeout
    assert ref == subscription.ref

    coordinator = ControlPoint.whereis(control_point)
    Process.exit(coordinator, :kill)

    assert_receive {:upnp, ref,
                    %Lifecycle{
                      kind: :lost,
                      reason: {:control_point, :internal_restart}
                    }},
                   @async_timeout

    assert ref == subscription.ref
    assert Process.alive?(control_point)
  end

  test "an abrupt terminal stop notifies GENA consumers without a goodbye", %{
    control_point: control_point,
    service: service,
    task_supervisor: task_supervisor
  } do
    subscriber = self()

    subscribing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Service.subscribe(service, subscriber: subscriber)
      end)

    assert_receive {:route_requested, _event_url, {:ok, {192, 0, 2, 25}}}, @async_timeout

    assert_receive {:eventing_transport, operation,
                    {:subscribe, event_url, _callback_url, 4_000, _options}},
                   @async_timeout

    send(operation, {
      :eventing_transport_reply,
      {:ok, %{sid: "uuid:terminal", timeout: 4_000}}
    })

    assert {:ok, subscription, []} = Task.await(subscribing, @async_timeout)
    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed}}, @async_timeout
    assert ref == subscription.ref

    monitor = Process.monitor(control_point)
    Process.exit(control_point, :kill)

    assert_receive {:upnp, ^ref,
                    %Lifecycle{
                      kind: :lost,
                      reason: {:control_point, :terminal_stop}
                    }},
                   @async_timeout

    assert_receive {:DOWN, ^monitor, :process, ^control_point, :killed}, @async_timeout
    refute_receive {:eventing_transport, _worker, {:unsubscribe, ^event_url, _sid, _options}}
  end

  test "owner loss during graceful GENA detach emits one terminal reason", %{
    control_point: control_point,
    service: service,
    task_supervisor: task_supervisor
  } do
    subscriber = self()

    subscribing =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Service.subscribe(service, subscriber: subscriber)
      end)

    assert_receive {:route_requested, _event_url, {:ok, {192, 0, 2, 25}}}, @async_timeout

    assert_receive {:eventing_transport, operation,
                    {:subscribe, _event_url, _callback_url, 4_000, _options}},
                   @async_timeout

    send(operation, {
      :eventing_transport_reply,
      {:ok, %{sid: "uuid:detach-race", timeout: 4_000}}
    })

    assert {:ok, subscription, []} = Task.await(subscribing, @async_timeout)
    subscription_ref = subscription.ref
    assert_receive {:upnp, ^subscription_ref, %Lifecycle{kind: :subscribed}}, @async_timeout
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)

    on_exit(fn ->
      if Process.alive?(control_point), do: :sys.resume(control_point)
    end)

    :ok = :sys.suspend(control_point)

    spawn(fn ->
      Manager.close(manager, :infinity, {:control_point, :graceful_close})
    end)

    await_queued_message(control_point)
    Process.exit(control_point, :kill)

    assert_receive {:upnp, ^subscription_ref,
                    %Lifecycle{
                      kind: :lost,
                      reason: {:control_point, :terminal_stop}
                    }},
                   @async_timeout

    refute_receive {:upnp, ^subscription_ref,
                    %Lifecycle{
                      kind: :lost,
                      reason: {:control_point, :graceful_close}
                    }}

    refute_receive {:upnp, ^subscription_ref, %Lifecycle{kind: :lost}}
  end

  test "an arbitrary eventing-manager exit becomes tagged availability data", %{
    control_point: control_point,
    service: service
  } do
    subscriber = self()
    test = self()

    caller =
      spawn(fn ->
        result = Service.subscribe(service, subscriber: subscriber)
        send(test, {:eventing_result, self(), result})
      end)

    assert_receive {:route_requested, _event_url, {:ok, {192, 0, 2, 25}}}, @async_timeout

    assert_receive {:eventing_transport, _operation,
                    {:subscribe, _event_url, _callback_url, 4_000, _options}},
                   @async_timeout

    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    Process.exit(manager, :boom)

    assert_receive {:eventing_result, ^caller, {:error, :eventing_unavailable}}, @async_timeout
    assert Process.alive?(control_point)
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

  defp await_queued_message(process, attempts \\ 1_000)

  defp await_queued_message(_process, 0), do: flunk("process did not receive a message")

  defp await_queued_message(process, attempts) do
    case Process.info(process, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _other ->
        :erlang.yield()
        await_queued_message(process, attempts - 1)
    end
  end
end
