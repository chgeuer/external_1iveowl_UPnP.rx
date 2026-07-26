defmodule UPnP.Eventing.RuntimeTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias UPnP.Clock.Manual
  alias UPnP.Eventing.{CallbackPlug, Event, Lifecycle, Manager, Subscription}
  alias UPnP.HTTP.{Request, Response}

  @event_url "http://device:80/events"
  @initial """
  <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
    <e:property><Volume>10</Volume></e:property>
    <e:property><Mute>0</Mute></e:property>
  </e:propertyset>
  """

  defmodule FakeTransport do
    @behaviour UPnP.Eventing.Transport

    @impl true
    def subscribe(test_pid, event_url, callback_url, timeout, options) do
      request(test_pid, {:subscribe, event_url, callback_url, timeout, options})
    end

    @impl true
    def renew(test_pid, event_url, sid, timeout, options) do
      request(test_pid, {:renew, event_url, sid, timeout, options})
    end

    @impl true
    def unsubscribe(test_pid, event_url, sid, options) do
      request(test_pid, {:unsubscribe, event_url, sid, options})
    end

    defp request(test_pid, request) do
      send(test_pid, {:transport, elem(request, 0), self(), request})

      receive do
        {:transport_reply, result} -> result
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
    %{clock: clock}
  end

  test "keeps missing and wildcard callback routes as tagged failures", %{clock: clock} do
    failures = [
      {{:error, :no_route}, {:callback_address_unavailable, :no_route}},
      {{:ok, {0, 0, 0, 0}}, {:callback_address_unavailable, :wildcard_address}}
    ]

    Enum.each(failures, fn {result, expected} ->
      manager =
        start_manager(clock,
          callback_bind: :any,
          network_adapter: {FakeNetwork, {self(), result}}
        )

      assert {:error, ^expected} = Manager.subscribe(manager, @event_url)
      assert_receive {:route_requested, %URI{host: "device"}, ^result}
      refute_receive {:transport, :subscribe, _, _}
    end)
  end

  test "starts lazily, shares canonical URLs, replays state, and stops on last close", %{
    clock: clock
  } do
    manager = start_manager(clock)
    assert Manager.callback_port(manager) == nil

    {subscription, callback} = establish(manager, "uuid:one", 4_000)
    assert Manager.callback_port(manager) == callback.port
    assert {:ok, %{port: port}} = Manager.callback_info(manager)
    assert port == callback.port

    token = callback_token(callback)
    assert :ok = Manager.deliver_callback(manager, token, "uuid:one", 0, @initial)

    assert_receive {:upnp, ref, %Event{sequence: 0, initial?: true} = event}
    assert ref == subscription.ref
    assert Enum.map(event.snapshot, &{&1.name, &1.value}) == [{"Volume", "10"}, {"Mute", "0"}]

    assert :ok =
             Manager.deliver_callback(
               manager,
               token,
               "uuid:one",
               1,
               property_set("Volume", "11")
             )

    assert_receive {:upnp, ^ref, %Event{sequence: 1}}

    assert {:ok, second, replay} =
             Manager.subscribe(manager, "HTTP://DEVICE/events", self())

    assert Enum.map(replay, &{&1.name, &1.value}) == [{"Volume", "11"}, {"Mute", "0"}]
    refute_received {:transport, :subscribe, _, _}

    assert :ok = Manager.unsubscribe(subscription)
    refute_received {:transport, :unsubscribe, _, _}

    close = Task.async(fn -> Manager.unsubscribe(second) end)
    assert_receive {:transport, :unsubscribe, request_pid, {:unsubscribe, _, "uuid:one", _}}
    reply(request_pid, :ok)
    assert Task.await(close) == :ok
  end

  test "buffers an early NOTIFY and serves it as the atomic initial snapshot", %{clock: clock} do
    manager = start_manager(clock)
    subscriber = self()

    subscribe =
      Task.async(fn ->
        Manager.subscribe(manager, @event_url, subscriber)
      end)

    assert_receive {:transport, :subscribe, request_pid, {:subscribe, _, callback, 4_000, _}}

    request = %Request{
      method: "NOTIFY",
      url: callback,
      headers: gena_headers("uuid:early", 0),
      body: @initial
    }

    assert {:ok, %Response{status: 200}} =
             UPnP.HTTP.request(UPnP.HTTP.Finch, request)

    reply(request_pid, {:ok, %{sid: "uuid:early", timeout: 4_000}})

    assert {:ok, subscription, snapshot} = Task.await(subscribe)
    assert Enum.map(snapshot, &{&1.name, &1.value}) == [{"Volume", "10"}, {"Mute", "0"}]

    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed}}
    assert ref == subscription.ref
    refute_received {:upnp, ^ref, %Event{}}

    token = callback_token(callback)
    assert Manager.deliver_callback(manager, token, "uuid:wrong", 1, @initial) == {:error, 412}

    assert Manager.deliver_callback(manager, "unknown", "uuid:early", 1, @initial) ==
             {:error, 404}

    assert Manager.deliver_callback(manager, token, "uuid:early", 1, "<bad") == {:error, 400}

    graceful_unsubscribe(subscription, "uuid:early")
  end

  test "coalesces concurrent local subscribers behind one remote SUBSCRIBE", %{clock: clock} do
    manager = start_manager(clock)
    subscriber = self()

    first = Task.async(fn -> Manager.subscribe(manager, @event_url, subscriber) end)

    assert_receive {:transport, :subscribe, request_pid, {:subscribe, _, _callback, 4_000, _}}

    second = Task.async(fn -> Manager.subscribe(manager, @event_url, subscriber) end)
    reply(request_pid, {:ok, %{sid: "uuid:shared", timeout: 4_000}})

    assert {:ok, first_subscription, []} = Task.await(first)
    assert {:ok, second_subscription, []} = Task.await(second)
    refute first_subscription.ref == second_subscription.ref
    refute_received {:transport, :subscribe, _, _}

    assert_receive {:upnp, first_ref, %Lifecycle{kind: :subscribed}}
    assert_receive {:upnp, second_ref, %Lifecycle{kind: :subscribed}}

    assert MapSet.new([first_ref, second_ref]) ==
             MapSet.new([first_subscription.ref, second_subscription.ref])

    assert :ok = Manager.unsubscribe(first_subscription)
    graceful_unsubscribe(second_subscription, "uuid:shared")
  end

  test "a pending delegated subscriber death replies to the live caller", %{clock: clock} do
    manager = start_manager(clock)

    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    subscribe = Task.async(fn -> Manager.subscribe(manager, @event_url, subscriber) end)

    assert_receive {:transport, :subscribe, request_pid, {:subscribe, _, _callback, _, _}}

    subscriber_monitor = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^subscriber_monitor, :process, ^subscriber, :normal}

    reply(request_pid, {:ok, %{sid: "uuid:orphaned", timeout: 4_000}})
    assert Task.await(subscribe) == {:error, :subscriber_not_alive}

    assert_receive {:transport, :unsubscribe, goodbye, {:unsubscribe, _, "uuid:orphaned", _}}
    reply(goodbye, :ok)
  end

  test "renews at exactly seventy-five percent of the granted timeout", %{clock: clock} do
    manager = start_manager(clock)
    {subscription, _callback} = establish(manager, "uuid:renew", 4_000)

    assert :ok = Manual.advance(clock, 2_999)
    refute_received {:transport, :renew, _, _}

    assert :ok = Manual.advance(clock, 1)

    assert_receive {:transport, :renew, request_pid, {:renew, event_url, "uuid:renew", 4_000, _}}

    assert URI.to_string(event_url) == "http://device/events"
    reply(request_pid, {:ok, 8_000})

    assert_receive {:upnp, ref, %Lifecycle{kind: :renewed, timeout: 8_000}}
    assert ref == subscription.ref

    graceful_unsubscribe(subscription, "uuid:renew")
  end

  test "runs every transport operation under the configured task supervisor", %{clock: clock} do
    task_supervisor = start_supervised!(Task.Supervisor)
    manager = start_manager(clock, task_supervisor: task_supervisor)
    subscriber = self()

    subscribing = Task.async(fn -> Manager.subscribe(manager, @event_url, subscriber) end)

    assert_receive {:transport, :subscribe, subscribe_task, {:subscribe, _, _callback, 4_000, _}}

    assert subscribe_task in Task.Supervisor.children(task_supervisor)
    reply(subscribe_task, {:ok, %{sid: "uuid:supervised", timeout: 4_000}})

    assert {:ok, subscription, []} = Task.await(subscribing)
    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed}}
    assert ref == subscription.ref

    assert :ok = Manual.advance(clock, 3_000)
    assert_receive {:transport, :renew, renew_task, {:renew, _, "uuid:supervised", _, _}}
    assert renew_task in Task.Supervisor.children(task_supervisor)
    reply(renew_task, {:ok, 4_000})
    assert_receive {:upnp, ^ref, %Lifecycle{kind: :renewed}}

    worker = Manager.subscription_pid(manager, @event_url)
    worker_monitor = Process.monitor(worker)
    closing = Task.async(fn -> Manager.unsubscribe(subscription) end)

    assert_receive {:transport, :unsubscribe, unsubscribe_task,
                    {:unsubscribe, _, "uuid:supervised", _}}

    assert unsubscribe_task in Task.Supervisor.children(task_supervisor)
    reply(unsubscribe_task, :ok)

    assert Task.await(closing) == :ok
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}
    await_no_tasks(task_supervisor)
    assert :sys.get_state(clock).timers == %{}
  end

  test "transport task crashes become lifecycle data without crashing the worker", %{
    clock: clock
  } do
    task_supervisor = start_supervised!(Task.Supervisor)

    manager =
      start_manager(clock,
        task_supervisor: task_supervisor,
        auto_resubscribe: false
      )

    {subscription, _callback} = establish(manager, "uuid:task-crash", 4_000)
    worker = Manager.subscription_pid(manager, @event_url)

    assert :ok = Manual.advance(clock, 3_000)

    assert_receive {:transport, :renew, renew_task, {:renew, _, "uuid:task-crash", 4_000, _}}

    assert renew_task in Task.Supervisor.children(task_supervisor)
    task_monitor = Process.monitor(renew_task)
    Process.exit(renew_task, :kill)

    assert_receive {:DOWN, ^task_monitor, :process, ^renew_task, :killed}

    assert_receive {:upnp, ref,
                    %Lifecycle{
                      kind: :lost,
                      reason: {:renewal_failed, {:operation_exit, :killed}}
                    }}

    assert ref == subscription.ref
    assert Process.alive?(worker)
    assert Subscription.debug_state(worker).status == :lost
    await_no_tasks(task_supervisor)

    graceful_unsubscribe(subscription, "uuid:task-crash")
  end

  test "manual-clock timeout kills the task and emits renewal loss", %{clock: clock} do
    task_supervisor = start_supervised!(Task.Supervisor)

    manager =
      start_manager(clock,
        task_supervisor: task_supervisor,
        operation_timeout: 100,
        auto_resubscribe: false
      )

    {subscription, _callback} = establish(manager, "uuid:task-timeout", 4_000)
    worker = Manager.subscription_pid(manager, @event_url)

    assert :ok = Manual.advance(clock, 3_000)

    assert_receive {:transport, :renew, renew_task, {:renew, _, "uuid:task-timeout", 4_000, _}}

    task_monitor = Process.monitor(renew_task)
    assert :ok = Manual.advance(clock, 99)
    assert Process.alive?(renew_task)
    refute_received {:upnp, _, %Lifecycle{kind: :lost}}

    assert :ok = Manual.advance(clock, 1)
    assert_receive {:DOWN, ^task_monitor, :process, ^renew_task, :killed}

    assert_receive {:upnp, ref, %Lifecycle{kind: :lost, reason: {:renewal_failed, :timeout}}}

    assert ref == subscription.ref
    assert Subscription.debug_state(worker).status == :lost
    await_no_tasks(task_supervisor)

    graceful_unsubscribe(subscription, "uuid:task-timeout")
  end

  test "graceful close cancels in-flight work and ignores its late result", %{clock: clock} do
    task_supervisor = start_supervised!(Task.Supervisor)
    manager = start_manager(clock, task_supervisor: task_supervisor)
    {subscription, _callback} = establish(manager, "uuid:cancelled", 4_000)
    worker = Manager.subscription_pid(manager, @event_url)
    worker_monitor = Process.monitor(worker)

    assert :ok = Manual.advance(clock, 3_000)
    assert_receive {:transport, :renew, renew_task, {:renew, _, "uuid:cancelled", 4_000, _}}

    operation_ref = :sys.get_state(worker).operation.task.ref
    task_monitor = Process.monitor(renew_task)
    closing = Task.async(fn -> Manager.unsubscribe(subscription) end)

    assert_receive {:DOWN, ^task_monitor, :process, ^renew_task, :killed}

    assert_receive {:transport, :unsubscribe, unsubscribe_task,
                    {:unsubscribe, _, "uuid:cancelled", _}}

    send(worker, {operation_ref, {:ok, 8_000}})

    state = :sys.get_state(worker)
    assert state.status == :closing
    assert state.operation.task.pid == unsubscribe_task
    refute_received {:upnp, _, %Lifecycle{kind: :renewed}}

    reply(unsubscribe_task, :ok)
    assert Task.await(closing) == :ok
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}
    refute_received {:transport, :unsubscribe, _, _}
    await_no_tasks(task_supervisor)
    assert :sys.get_state(clock).timers == %{}
  end

  test "renewal loss unsubscribes, rotates the route, and resubscribes", %{clock: clock} do
    manager = start_manager(clock)
    {subscription, first_callback} = establish(manager, "uuid:first", 4_000)

    assert :ok = Manual.advance(clock, 3_000)
    assert_receive {:transport, :renew, renew_pid, {:renew, _, "uuid:first", _, _}}
    reply(renew_pid, {:error, {:http_status, 412, ""}})

    assert_receive {:upnp, ref, %Lifecycle{kind: :lost}}
    assert ref == subscription.ref
    assert_receive {:upnp, ^ref, %Lifecycle{kind: :resubscribing}}

    assert_receive {:transport, :unsubscribe, unsubscribe_pid, {:unsubscribe, _, "uuid:first", _}}

    reply(unsubscribe_pid, :ok)

    assert_receive {:transport, :subscribe, subscribe_pid,
                    {:subscribe, _, second_callback, 4_000, _}}

    refute callback_token(first_callback) == callback_token(second_callback)
    reply(subscribe_pid, {:ok, %{sid: "uuid:second", timeout: 8_000}})

    assert_receive {:upnp, ^ref,
                    %Lifecycle{kind: :resubscribed, sid: "uuid:second", timeout: 8_000}}

    assert Manager.deliver_callback(
             manager,
             callback_token(first_callback),
             "uuid:first",
             0,
             @initial
           ) == {:error, 404}

    graceful_unsubscribe(subscription, "uuid:second")
  end

  test "initial failures use bounded clock-driven retry and return tagged data", %{clock: clock} do
    manager = start_manager(clock, retry_backoff: [100])
    subscriber = self()

    subscribe = Task.async(fn -> Manager.subscribe(manager, @event_url, subscriber) end)

    assert_receive {:transport, :subscribe, first_pid, {:subscribe, _, first_callback, _, _}}

    worker = Manager.subscription_pid(manager, @event_url)
    reply(first_pid, {:error, :econnrefused})
    await_status(worker, :retry_wait)

    assert :ok = Manual.advance(clock, 99)
    refute_received {:transport, :subscribe, _, _}
    assert :ok = Manual.advance(clock, 1)

    assert_receive {:transport, :subscribe, second_pid, {:subscribe, _, second_callback, _, _}}

    refute callback_token(first_callback) == callback_token(second_callback)
    reply(second_pid, {:error, :econnrefused})

    assert Task.await(subscribe) == {:error, {:subscribe_failed, :econnrefused}}
  end

  test "tracks gaps, duplicates, stale events, and a 32-bit wrap", %{clock: clock} do
    manager = start_manager(clock, auto_resubscribe: false)
    {subscription, callback} = establish(manager, "uuid:sequence", 4_000)
    token = callback_token(callback)

    maximum = 4_294_967_295
    body = property_set("State", "maximum")

    assert :ok = Manager.deliver_callback(manager, token, "uuid:sequence", maximum, body)

    assert_receive {:upnp, ref,
                    %Lifecycle{
                      kind: :sequence_gap,
                      expected_sequence: 0,
                      actual_sequence: ^maximum
                    }}

    assert ref == subscription.ref
    assert_receive {:upnp, ^ref, %Event{sequence: ^maximum}}

    assert :ok =
             Manager.deliver_callback(
               manager,
               token,
               "uuid:sequence",
               1,
               property_set("State", "wrapped")
             )

    assert_receive {:upnp, ^ref, %Event{sequence: 1}}
    refute_received {:upnp, ^ref, %Lifecycle{kind: :sequence_gap}}

    assert :ok = Manager.deliver_callback(manager, token, "uuid:sequence", 1, body)
    assert_receive {:upnp, ^ref, %Lifecycle{kind: :duplicate, actual_sequence: 1}}

    assert :ok = Manager.deliver_callback(manager, token, "uuid:sequence", maximum, body)
    assert_receive {:upnp, ^ref, %Lifecycle{kind: :stale, actual_sequence: ^maximum}}

    graceful_unsubscribe(subscription, "uuid:sequence")
  end

  test "a sequence gap recovers with a fresh full snapshot", %{clock: clock} do
    manager = start_manager(clock)
    {subscription, first_callback} = establish(manager, "uuid:gap-one", 4_000)
    first_token = callback_token(first_callback)

    assert :ok =
             Manager.deliver_callback(manager, first_token, "uuid:gap-one", 0, @initial)

    assert_receive {:upnp, ref, %Event{sequence: 0}}
    assert ref == subscription.ref

    assert :ok =
             Manager.deliver_callback(
               manager,
               first_token,
               "uuid:gap-one",
               2,
               property_set("Volume", "99")
             )

    assert_receive {:upnp, ^ref, %Lifecycle{kind: :sequence_gap}}
    assert_receive {:upnp, ^ref, %Lifecycle{kind: :resubscribing}}

    assert_receive {:transport, :unsubscribe, goodbye_pid, {:unsubscribe, _, "uuid:gap-one", _}}

    reply(goodbye_pid, :ok)
    assert_receive {:transport, :subscribe, subscribe_pid, {:subscribe, _, callback, _, _}}
    reply(subscribe_pid, {:ok, %{sid: "uuid:gap-two", timeout: 4_000}})

    assert_receive {:upnp, ^ref, %Lifecycle{kind: :resubscribed}}

    assert {:ok, late, []} = Manager.subscribe(manager, @event_url)

    assert :ok =
             Manager.deliver_callback(
               manager,
               callback_token(callback),
               "uuid:gap-two",
               0,
               property_set("Volume", "20")
             )

    assert_receive {:upnp, ^ref, %Event{initial?: true, snapshot: [property]}}
    assert property.value == "20"

    graceful_unsubscribe(subscription, "uuid:gap-two", false)
    graceful_unsubscribe(late, "uuid:gap-two")
  end

  test "consumer death is graceful but owner death is abrupt", %{clock: clock} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    manager = start_manager(clock, owner: owner)
    {subscription, _callback} = establish(manager, "uuid:owned", 4_000)

    consumer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, _consumer_subscription, []} =
             Manager.subscribe(manager, @event_url, consumer)

    assert :ok = Manager.unsubscribe(subscription)

    consumer_monitor = Process.monitor(consumer)
    send(consumer, :stop)
    assert_receive {:DOWN, ^consumer_monitor, :process, ^consumer, :normal}

    assert_receive {:transport, :unsubscribe, first_goodbye, {:unsubscribe, _, "uuid:owned", _}}

    reply(first_goodbye, :ok)

    {_second_subscription, _callback} =
      establish(manager, "uuid:owned-again", 4_000)

    manager_monitor = Process.monitor(manager)
    send(owner, :stop)

    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, :normal}
    refute_received {:transport, :unsubscribe, _, _}
  end

  test "abrupt manager shutdown cancels transport work without a goodbye", %{clock: clock} do
    task_supervisor = start_supervised!(Task.Supervisor)
    manager = start_manager(clock, task_supervisor: task_supervisor)
    {_subscription, _callback} = establish(manager, "uuid:abrupt", 4_000)
    worker = Manager.subscription_pid(manager, @event_url)
    worker_monitor = Process.monitor(worker)
    manager_monitor = Process.monitor(manager)

    assert :ok = Manual.advance(clock, 3_000)
    assert_receive {:transport, :renew, renew_task, {:renew, _, "uuid:abrupt", 4_000, _}}
    task_monitor = Process.monitor(renew_task)

    assert :ok = Manager.stop(manager)
    assert_receive {:DOWN, ^task_monitor, :process, ^renew_task, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, :normal}
    refute_received {:transport, :unsubscribe, _, _}
    await_no_tasks(task_supervisor)
    assert :sys.get_state(clock).timers == %{}
  end

  test "graceful goodbye is bounded by the injected clock", %{clock: clock} do
    manager = start_manager(clock, operation_timeout: 100)
    {subscription, _callback} = establish(manager, "uuid:bounded-close", 4_000)

    close = Task.async(fn -> Manager.unsubscribe(subscription) end)

    assert_receive {:transport, :unsubscribe, _request_pid,
                    {:unsubscribe, _, "uuid:bounded-close", _}}

    worker = find_stopping_worker(manager)
    assert Subscription.debug_state(worker).status == :closing

    assert :ok = Manual.advance(clock, 100)
    assert Task.await(close) == :ok
  end

  test "abrupt worker death emits loss data but no goodbye", %{clock: clock} do
    manager = start_manager(clock)
    {subscription, _callback} = establish(manager, "uuid:worker-crash", 4_000)
    worker = Manager.subscription_pid(manager, @event_url)
    worker_monitor = Process.monitor(worker)

    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}

    assert_receive {:upnp, ref, %Lifecycle{kind: :lost, reason: {:worker_exit, :killed}}}

    assert ref == subscription.ref
    refute_received {:transport, :unsubscribe, _, _}
    assert Manager.subscription_pid(manager, @event_url) == nil
  end

  test "callback Plug rejects unknown, malformed, wrong-SID, and oversized requests", %{
    clock: clock
  } do
    manager = start_manager(clock)
    {subscription, callback} = establish(manager, "uuid:plug", 4_000)
    segments = String.split(callback.path, "/", trim: true)
    [manager_token, _token] = Enum.take(segments, -2)
    prefix = Enum.drop(segments, -2)

    options =
      CallbackPlug.init(
        manager: manager,
        manager_token: manager_token,
        path_prefix: prefix,
        max_body_bytes: 1_024
      )

    unknown_path = "/" <> Enum.join(prefix ++ [manager_token, "unknown"], "/")

    assert callback_conn("NOTIFY", unknown_path, @initial)
           |> CallbackPlug.call(options)
           |> status() == 404

    assert callback_conn("GET", callback.path, "") |> CallbackPlug.call(options) |> status() ==
             405

    assert callback_conn("NOTIFY", callback.path, @initial)
           |> put_req_header("sid", "uuid:plug")
           |> put_req_header("seq", "0")
           |> put_req_header("nts", "upnp:propchange")
           |> put_req_header("content-type", "text/xml")
           |> CallbackPlug.call(options)
           |> status() == 400

    assert callback_conn("NOTIFY", callback.path, @initial)
           |> add_gena_headers("uuid:plug", "bad")
           |> CallbackPlug.call(options)
           |> status() == 400

    assert callback_conn("NOTIFY", callback.path, @initial)
           |> add_gena_headers("uuid:wrong", "0")
           |> CallbackPlug.call(options)
           |> status() == 412

    assert callback_conn("NOTIFY", callback.path, @initial)
           |> add_gena_headers("uuid:plug", "0", "application/json")
           |> CallbackPlug.call(options)
           |> status() == 415

    small_options = %{options | max_body_bytes: 8}

    assert callback_conn("NOTIFY", callback.path, @initial)
           |> add_gena_headers("uuid:plug", "0")
           |> CallbackPlug.call(small_options)
           |> status() == 413

    assert callback_conn("NOTIFY", callback.path, @initial)
           |> add_gena_headers("uuid:plug", "0")
           |> CallbackPlug.call(options)
           |> status() == 200

    assert_receive {:upnp, ref, %Event{sequence: 0}}
    assert ref == subscription.ref

    graceful_unsubscribe(subscription, "uuid:plug")
  end

  defp start_manager(clock, options \\ []) do
    unique = System.unique_integer([:positive])

    subscriptions =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one},
        id: {:subscription_supervisor, unique}
      )

    servers =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one},
        id: {:server_supervisor, unique}
      )

    defaults = [
      owner: self(),
      clock: {Manual, clock},
      transport: {FakeTransport, self()},
      task_supervisor:
        Keyword.get_lazy(options, :task_supervisor, fn ->
          start_supervised!(Task.Supervisor, id: {:task_supervisor, unique})
        end),
      callback_bind: {127, 0, 0, 1},
      callback_port: 0,
      subscription_timeout: 4_000,
      subscription_supervisor: subscriptions,
      server_supervisor: servers
    ]

    start_supervised!({Manager, Keyword.merge(defaults, options)}, id: {:manager, unique})
  end

  defp establish(manager, sid, timeout) do
    subscriber = self()
    subscribe = Task.async(fn -> Manager.subscribe(manager, @event_url, subscriber) end)

    assert_receive {:transport, :subscribe, request_pid,
                    {:subscribe, event_url, callback, requested_timeout, _options}}

    assert URI.to_string(event_url) == "http://device/events"
    assert requested_timeout == 4_000
    reply(request_pid, {:ok, %{sid: sid, timeout: timeout}})

    assert {:ok, subscription, []} = Task.await(subscribe)
    assert_receive {:upnp, ref, %Lifecycle{kind: :subscribed, sid: ^sid, timeout: ^timeout}}
    assert ref == subscription.ref
    {subscription, callback}
  end

  defp graceful_unsubscribe(subscription, sid, expect_request? \\ true) do
    close = Task.async(fn -> Manager.unsubscribe(subscription) end)

    if expect_request? do
      assert_receive {:transport, :unsubscribe, request_pid, {:unsubscribe, _, ^sid, _}}
      reply(request_pid, :ok)
    end

    assert Task.await(close) == :ok
  end

  defp reply(pid, result), do: send(pid, {:transport_reply, result})

  defp callback_token(%URI{path: path}) do
    path |> String.split("/", trim: true) |> List.last()
  end

  defp gena_headers(sid, sequence) do
    [
      {"NT", "upnp:event"},
      {"NTS", "upnp:propchange"},
      {"SID", sid},
      {"SEQ", Integer.to_string(sequence)},
      {"Content-Type", "text/xml; charset=\"utf-8\""}
    ]
  end

  defp property_set(name, value) do
    """
    <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
      <e:property><#{name}>#{value}</#{name}></e:property>
    </e:propertyset>
    """
  end

  defp callback_conn(method, path, body), do: Plug.Test.conn(method, path, body)

  defp add_gena_headers(conn, sid, sequence, content_type \\ "text/xml") do
    conn
    |> put_req_header("nt", "upnp:event")
    |> put_req_header("nts", "upnp:propchange")
    |> put_req_header("sid", sid)
    |> put_req_header("seq", sequence)
    |> put_req_header("content-type", content_type)
  end

  defp status(%Plug.Conn{status: status}), do: status

  defp await_status(worker, expected, attempts \\ 10_000)

  defp await_status(_worker, expected, 0),
    do: flunk("worker did not enter #{inspect(expected)}")

  defp await_status(worker, expected, attempts) do
    case Subscription.debug_state(worker).status do
      ^expected ->
        :ok

      _other ->
        :erlang.yield()
        await_status(worker, expected, attempts - 1)
    end
  end

  defp await_no_tasks(supervisor, attempts \\ 10_000)

  defp await_no_tasks(_supervisor, 0), do: flunk("task supervisor still has children")

  defp await_no_tasks(supervisor, attempts) do
    case Task.Supervisor.children(supervisor) do
      [] ->
        :ok

      _children ->
        :erlang.yield()
        await_no_tasks(supervisor, attempts - 1)
    end
  end

  defp find_stopping_worker(manager) do
    manager
    |> :sys.get_state()
    |> Map.fetch!(:stopping)
    |> Map.keys()
    |> List.first()
  end
end
