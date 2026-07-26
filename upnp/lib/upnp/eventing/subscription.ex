defmodule UPnP.Eventing.Subscription do
  @moduledoc """
  Supervised worker for one shared remote GENA subscription.

  The manager owns local subscribers; this worker owns remote SID, renewal,
  retry, sequence, and last-known-property state.
  """

  use GenServer

  alias UPnP.Eventing.{Event, Lifecycle, Manager, Transport}

  @sequence_modulus 4_294_967_296
  @sequence_half 2_147_483_648
  @maximum_sequence 4_294_967_295

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Starts a shared remote subscription worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Returns the worker's immutable current property snapshot."
  @spec snapshot(GenServer.server()) :: [UPnP.EventedProperty.t()]
  def snapshot(worker), do: GenServer.call(worker, :snapshot)

  @doc false
  @spec notify(
          GenServer.server(),
          String.t(),
          String.t(),
          non_neg_integer(),
          [UPnP.EventedProperty.t()]
        ) :: :ok
  def notify(worker, token, sid, sequence, properties) do
    GenServer.cast(worker, {:notify, token, sid, sequence, properties})
  end

  @doc false
  @spec graceful_stop(GenServer.server()) :: :ok
  def graceful_stop(worker), do: GenServer.cast(worker, :graceful_stop)

  @doc false
  @spec callback_server_down(GenServer.server(), term()) :: :ok
  def callback_server_down(worker, reason) do
    GenServer.cast(worker, {:callback_server_down, reason})
  end

  @doc false
  @spec debug_state(GenServer.server()) :: map()
  def debug_state(worker), do: GenServer.call(worker, :debug_state)

  @impl true
  def init(options) do
    # Supervisor shutdown must run terminate/2 to cancel clock timers and in-flight tasks.
    Process.flag(:trap_exit, true)

    manager = Keyword.fetch!(options, :manager)

    state = %{
      manager: manager,
      manager_monitor: Process.monitor(manager),
      key: Keyword.fetch!(options, :key),
      event_url: Keyword.fetch!(options, :event_url),
      callback_token: Keyword.fetch!(options, :callback_token),
      callback_url: Keyword.fetch!(options, :callback_url),
      clock: Keyword.get(options, :clock, UPnP.Clock.System),
      transport: Keyword.get(options, :transport, UPnP.Eventing.Transport.HTTP),
      transport_options: Keyword.get(options, :transport_options, []),
      task_supervisor: Keyword.fetch!(options, :task_supervisor),
      requested_timeout: Keyword.get(options, :subscription_timeout, 1_800_000),
      operation_timeout: Keyword.get(options, :operation_timeout, 30_000),
      auto_resubscribe: Keyword.get(options, :auto_resubscribe, true),
      retry_backoff: Keyword.get(options, :retry_backoff, [1_000, 2_000, 5_000, 10_000]),
      max_early_notifications: Keyword.get(options, :max_early_notifications, 32),
      status: :subscribing,
      sid: nil,
      granted_timeout: nil,
      last_sequence: nil,
      snapshot: %{},
      snapshot_order: [],
      early_notifications: [],
      operation: nil,
      renewal_timer: nil,
      retry_timer: nil,
      retry_count: 0,
      pending_goodbye_sid: nil,
      ever_subscribed: false,
      announced_ready: false
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    {:noreply, start_subscribe_operation(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_values(state), state}

  def handle_call(:debug_state, _from, state) do
    debug =
      Map.take(state, [
        :status,
        :sid,
        :granted_timeout,
        :last_sequence,
        :callback_token,
        :retry_count,
        :ever_subscribed,
        :announced_ready
      ])
      |> Map.put(:snapshot, snapshot_values(state))

    {:reply, debug, state}
  end

  @impl true
  def handle_cast(
        {:notify, token, sid, sequence, properties},
        %{status: status} = state
      )
      when status in [:subscribing, :resubscribing] do
    notification = %{token: token, sid: sid, sequence: sequence, properties: properties}

    state =
      if token == state.callback_token do
        %{state | early_notifications: bounded_append(state, notification)}
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:notify, token, sid, sequence, properties}, %{status: :live} = state) do
    if token == state.callback_token and sid == state.sid do
      {:noreply, process_notification(state, sequence, properties)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:notify, _token, _sid, _sequence, _properties}, state) do
    {:noreply, state}
  end

  def handle_cast(:graceful_stop, %{status: :closing} = state), do: {:noreply, state}

  def handle_cast(:graceful_stop, state) do
    state =
      state
      |> cancel_protocol_timers()
      |> stop_operation()
      |> Map.put(:status, :closing)

    if state.sid do
      {:noreply, start_close_operation(state)}
    else
      notify_stopped(state, :ok)
      {:stop, :normal, state}
    end
  end

  def handle_cast({:callback_server_down, _reason}, %{status: :closing} = state) do
    {:noreply, state}
  end

  def handle_cast({:callback_server_down, reason}, state) do
    state = state |> cancel_protocol_timers() |> stop_operation()

    cond do
      not state.announced_ready and not state.auto_resubscribe ->
        fail_initial(state, {:callback_server_down, reason})

      state.announced_ready and not state.auto_resubscribe ->
        state =
          state
          |> emit_lifecycle(:lost, sid: state.sid, reason: {:callback_server_down, reason})
          |> disable_callback_preserving_sid()
          |> Map.put(:status, :lost)

        {:noreply, state}

      true ->
        state =
          if state.announced_ready do
            emit_lifecycle(state, :lost,
              sid: state.sid,
              reason: {:callback_server_down, reason}
            )
          else
            state
          end

        {:noreply, begin_recovery(state, {:callback_server_down, reason})}
    end
  end

  @impl true
  def handle_info({ref, result}, %{operation: %{task: %{ref: ref}, kind: kind}} = state) do
    state = clear_operation(state)
    handle_operation_result(kind, result, state)
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:renew, generation}, %{renewal_timer: {_timer, generation}} = state) do
    state = %{state | renewal_timer: nil}

    if state.status == :live and is_nil(state.operation) do
      operation = fn ->
        Transport.renew(
          state.transport,
          state.event_url,
          state.sid,
          state.requested_timeout,
          state.transport_options
        )
      end

      {:noreply, start_operation(state, :renew, operation)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:renew, _generation}, state), do: {:noreply, state}

  def handle_info({:retry_subscribe, generation}, %{retry_timer: {_timer, generation}} = state) do
    state = %{state | retry_timer: nil}
    {:noreply, start_retry_attempt(state)}
  end

  def handle_info({:retry_subscribe, _generation}, state), do: {:noreply, state}

  def handle_info(
        {:operation_timeout, operation_ref},
        %{operation: %{task: %{ref: operation_ref}, kind: kind}} = state
      ) do
    state = stop_operation(state)
    handle_operation_result(kind, {:error, :timeout}, state)
  end

  def handle_info({:operation_timeout, _operation_ref}, state), do: {:noreply, state}

  def handle_info({:terminate_failed, reason}, %{status: :failed} = state) do
    notify_failed(state, reason)
    {:stop, :normal, state}
  end

  def handle_info({:terminate_failed, _reason}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{manager_monitor: monitor} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{operation: %{task: %{ref: ref, pid: pid}}} = state
      ) do
    kind = state.operation.kind
    state = clear_operation(state)
    handle_operation_result(kind, {:error, {:operation_exit, reason}}, state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> cancel_protocol_timers()
    |> stop_operation()

    :ok
  end

  defp handle_operation_result(:subscribe, result, state) do
    case subscription_result(result, state.requested_timeout) do
      {:ok, sid, granted_timeout} ->
        establish_subscription(state, sid, granted_timeout)

      {:error, reason} ->
        {:noreply, handle_subscribe_failure(state, reason)}
    end
  end

  defp handle_operation_result(:renew, result, state) do
    case renewal_result(result, state.granted_timeout) do
      {:ok, granted_timeout} ->
        state =
          state
          |> Map.put(:granted_timeout, granted_timeout)
          |> emit_lifecycle(:renewed, sid: state.sid, timeout: granted_timeout)
          |> schedule_renewal()

        {:noreply, state}

      {:error, reason} ->
        state =
          emit_lifecycle(state, :lost,
            sid: state.sid,
            reason: {:renewal_failed, reason}
          )

        if state.auto_resubscribe do
          {:noreply, begin_recovery(state, {:renewal_failed, reason})}
        else
          {:noreply, state |> disable_callback_preserving_sid() |> Map.put(:status, :lost)}
        end
    end
  end

  defp handle_operation_result(:close, result, state) do
    notify_stopped(state, result)
    {:stop, :normal, %{state | sid: nil}}
  end

  defp establish_subscription(state, sid, granted_timeout) do
    case manager_bind(state, sid) do
      :ok ->
        state = %{
          state
          | status: :live,
            sid: sid,
            granted_timeout: granted_timeout,
            last_sequence: nil,
            retry_count: 0,
            retry_timer: nil,
            pending_goodbye_sid: nil,
            ever_subscribed: true
        }

        state =
          if state.announced_ready do
            emit_lifecycle(state, :resubscribed, sid: sid, timeout: granted_timeout)
          else
            state
          end

        state = replay_early_notifications(state)

        if state.status == :live do
          state = schedule_renewal(state)

          if state.announced_ready do
            {:noreply, state}
          else
            lifecycle =
              lifecycle(state, :subscribed, sid: sid, timeout: granted_timeout)

            send(
              state.manager,
              {:eventing_worker_ready, state.key, self(), lifecycle}
            )

            {:noreply, %{state | announced_ready: true}}
          end
        else
          {:noreply, state}
        end

      {:error, :manager_unavailable} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        state = %{state | sid: sid, status: :closing}
        {:noreply, start_close_operation(state)}
    end
  end

  defp handle_subscribe_failure(state, reason) do
    cond do
      permanent_refusal?(reason) and not state.announced_ready ->
        terminal_initial_failure(state, {:subscription_refused, reason})

      permanent_refusal?(reason) ->
        state
        |> emit_lifecycle(:subscription_refused,
          reason: reason,
          attempt: state.retry_count
        )
        |> disable_callback()
        |> Map.put(:status, :lost)

      state.auto_resubscribe and state.retry_count < length(state.retry_backoff) ->
        schedule_retry(state, reason)

      state.announced_ready ->
        state
        |> emit_lifecycle(:retry_exhausted,
          reason: reason,
          attempt: state.retry_count
        )
        |> disable_callback()
        |> Map.put(:status, :lost)

      true ->
        terminal_initial_failure(state, {:subscribe_failed, reason})
    end
  end

  defp schedule_retry(state, reason) do
    delay = Enum.at(state.retry_backoff, state.retry_count)
    attempt = state.retry_count + 1
    generation = make_ref()
    timer = UPnP.Clock.send_after(state.clock, self(), {:retry_subscribe, generation}, delay)

    state =
      if state.announced_ready do
        emit_lifecycle(state, :resubscribe_failed,
          reason: reason,
          attempt: attempt
        )
      else
        state
      end

    %{
      state
      | status: :retry_wait,
        retry_count: attempt,
        retry_timer: {timer, generation}
    }
  end

  defp start_retry_attempt(state) do
    case rotate_callback(state) do
      {:ok, state} ->
        start_subscribe_operation(state)

      {:error, reason, state} ->
        handle_subscribe_failure(state, {:callback_unavailable, reason})
    end
  end

  defp begin_recovery(state, reason) do
    old_sid = state.sid || state.pending_goodbye_sid

    state =
      state
      |> cancel_protocol_timers()
      |> stop_operation()
      |> Map.merge(%{
        status: :resubscribing,
        sid: nil,
        granted_timeout: nil,
        last_sequence: nil,
        snapshot: %{},
        snapshot_order: [],
        early_notifications: [],
        retry_count: 0,
        pending_goodbye_sid: old_sid
      })

    state =
      if state.announced_ready do
        emit_lifecycle(state, :resubscribing, reason: reason)
      else
        state
      end

    case rotate_callback(state) do
      {:ok, state} ->
        start_subscribe_operation(state)

      {:error, rotate_reason, state} ->
        handle_subscribe_failure(state, {:callback_unavailable, rotate_reason})
    end
  end

  defp start_subscribe_operation(state) do
    goodbye_sid = state.pending_goodbye_sid

    operation = fn ->
      if goodbye_sid do
        _result =
          safe_transport(fn ->
            Transport.unsubscribe(
              state.transport,
              state.event_url,
              goodbye_sid,
              state.transport_options
            )
          end)
      end

      Transport.subscribe(
        state.transport,
        state.event_url,
        state.callback_url,
        state.requested_timeout,
        state.transport_options
      )
    end

    status = if state.announced_ready, do: :resubscribing, else: :subscribing

    state
    |> Map.put(:status, status)
    |> Map.put(:pending_goodbye_sid, nil)
    |> start_operation(:subscribe, operation)
  end

  defp start_close_operation(state) do
    sid = state.sid

    operation = fn ->
      Transport.unsubscribe(
        state.transport,
        state.event_url,
        sid,
        state.transport_options
      )
    end

    start_operation(state, :close, operation)
  end

  defp start_operation(%{operation: nil} = state, kind, function) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> safe_transport(function) end)

    timer =
      UPnP.Clock.send_after(
        state.clock,
        self(),
        {:operation_timeout, task.ref},
        state.operation_timeout
      )

    %{state | operation: %{task: task, kind: kind, timer: timer}}
  end

  defp safe_transport(function) do
    function.()
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp clear_operation(state) do
    cancel_operation_timer(state)
    Process.demonitor(state.operation.task.ref, [:flush])
    %{state | operation: nil}
  end

  defp stop_operation(%{operation: nil} = state), do: state

  defp stop_operation(state) do
    cancel_operation_timer(state)
    Task.shutdown(state.operation.task, :brutal_kill)
    %{state | operation: nil}
  end

  defp cancel_operation_timer(state) do
    try do
      UPnP.Clock.cancel_timer(state.clock, state.operation.timer)
    catch
      :exit, _reason -> false
    end
  end

  defp process_notification(state, sequence, properties) do
    case sequence_status(state.last_sequence, sequence) do
      :next ->
        accept_notification(state, sequence, properties)

      :duplicate ->
        emit_lifecycle(state, :duplicate,
          sid: state.sid,
          expected_sequence: expected_sequence(state.last_sequence),
          actual_sequence: sequence
        )

      :stale ->
        emit_lifecycle(state, :stale,
          sid: state.sid,
          expected_sequence: expected_sequence(state.last_sequence),
          actual_sequence: sequence
        )

      {:gap, expected} ->
        state =
          emit_lifecycle(state, :sequence_gap,
            sid: state.sid,
            expected_sequence: expected,
            actual_sequence: sequence
          )

        if state.auto_resubscribe do
          begin_recovery(state, {:sequence_gap, expected, sequence})
        else
          accept_notification(state, sequence, properties)
        end
    end
  end

  defp accept_notification(state, sequence, properties) do
    initial? = is_nil(state.last_sequence) and sequence == 0

    state =
      if initial? do
        replace_snapshot(state, properties)
      else
        merge_snapshot(state, properties)
      end

    state = %{state | last_sequence: sequence}

    if properties == [] do
      state
    else
      event = %Event{
        sid: state.sid,
        sequence: sequence,
        properties: properties,
        snapshot: snapshot_values(state),
        initial?: initial?,
        received_at: UPnP.Clock.utc_now(state.clock)
      }

      emit_event(state, event)
    end
  end

  defp sequence_status(nil, 0), do: :next
  defp sequence_status(nil, _actual), do: {:gap, 0}
  defp sequence_status(last, last), do: :duplicate
  defp sequence_status(@maximum_sequence, 1), do: :next

  defp sequence_status(last, actual) do
    expected = expected_sequence(last)

    cond do
      actual == expected ->
        :next

      modular_distance(last, actual) < @sequence_half ->
        {:gap, expected}

      true ->
        :stale
    end
  end

  defp expected_sequence(@maximum_sequence), do: 1
  defp expected_sequence(sequence), do: sequence + 1

  defp modular_distance(last, actual) do
    rem(actual - last + @sequence_modulus, @sequence_modulus)
  end

  defp replace_snapshot(state, properties) do
    {snapshot, order} = put_properties(%{}, [], properties)
    %{state | snapshot: snapshot, snapshot_order: order}
  end

  defp merge_snapshot(state, properties) do
    {snapshot, order} = put_properties(state.snapshot, state.snapshot_order, properties)
    %{state | snapshot: snapshot, snapshot_order: order}
  end

  defp put_properties(snapshot, order, properties) do
    Enum.reduce(properties, {snapshot, order}, fn property, {values, keys} ->
      key = property.name |> to_string() |> String.downcase()
      keys = if Map.has_key?(values, key), do: keys, else: keys ++ [key]
      {Map.put(values, key, property), keys}
    end)
  end

  defp snapshot_values(state), do: Enum.map(state.snapshot_order, &Map.fetch!(state.snapshot, &1))

  defp replay_early_notifications(state) do
    notifications = state.early_notifications
    state = %{state | early_notifications: []}

    Enum.reduce_while(notifications, state, fn notification, acc ->
      if acc.status == :live do
        if notification.token == acc.callback_token and notification.sid == acc.sid do
          {:cont, process_notification(acc, notification.sequence, notification.properties)}
        else
          {:cont, acc}
        end
      else
        {:halt, acc}
      end
    end)
  end

  defp bounded_append(state, notification) do
    notifications = state.early_notifications ++ [notification]
    overflow = length(notifications) - state.max_early_notifications
    if overflow > 0, do: Enum.drop(notifications, overflow), else: notifications
  end

  defp schedule_renewal(%{granted_timeout: :infinite} = state), do: state

  defp schedule_renewal(%{granted_timeout: timeout} = state)
       when is_integer(timeout) and timeout > 0 do
    delay = max(div(timeout * 3, 4), 1)
    generation = make_ref()
    timer = UPnP.Clock.send_after(state.clock, self(), {:renew, generation}, delay)
    %{state | renewal_timer: {timer, generation}}
  end

  defp schedule_renewal(state), do: state

  defp cancel_protocol_timers(state) do
    state
    |> cancel_timer(:renewal_timer)
    |> cancel_timer(:retry_timer)
  end

  defp cancel_timer(state, field) do
    case Map.fetch!(state, field) do
      {timer, _generation} ->
        try do
          UPnP.Clock.cancel_timer(state.clock, timer)
        catch
          :exit, _reason -> false
        end

        Map.put(state, field, nil)

      nil ->
        state
    end
  end

  defp rotate_callback(state) do
    try do
      case Manager.rotate_callback(state.manager, state.key, self()) do
        {:ok, callback_token, callback_url} ->
          {:ok,
           %{
             state
             | callback_token: callback_token,
               callback_url: callback_url,
               early_notifications: []
           }}

        {:error, reason} ->
          {:error, reason, state}
      end
    catch
      :exit, reason -> {:error, {:manager_unavailable, reason}, state}
    end
  end

  defp manager_bind(state, sid) do
    try do
      Manager.bind_sid(
        state.manager,
        state.key,
        self(),
        state.callback_token,
        sid
      )
    catch
      :exit, _reason -> {:error, :manager_unavailable}
    end
  end

  defp disable_callback(state) do
    Manager.disable_callback(state.manager, state.key, self())
    %{state | callback_token: nil, sid: nil}
  end

  defp disable_callback_preserving_sid(state) do
    sid = state.sid
    %{disable_callback(state) | sid: sid}
  end

  defp emit_event(state, event) do
    case event do
      %Event{properties: properties} ->
        UPnP.Telemetry.emit(
          [:upnp, :eventing, :notification],
          %{property_count: length(properties)},
          %{subscription: state.key, sid: event.sid, sequence: event.sequence}
        )

      %Lifecycle{} ->
        UPnP.Telemetry.emit([:upnp, :eventing, :lifecycle], %{}, %{
          subscription: state.key,
          kind: event.kind,
          sid: event.sid,
          reason: UPnP.Telemetry.classify_error(event.reason)
        })
    end

    send(state.manager, {:eventing_worker_event, state.key, self(), event})
    state
  end

  defp emit_lifecycle(state, kind, fields) do
    emit_event(state, lifecycle(state, kind, fields))
  end

  defp lifecycle(state, kind, fields) do
    struct!(
      Lifecycle,
      Keyword.merge(
        [kind: kind, occurred_at: UPnP.Clock.utc_now(state.clock)],
        fields
      )
    )
  end

  defp subscription_result({:ok, %{sid: sid, timeout: timeout}}, fallback)
       when is_binary(sid) do
    case String.trim(sid) do
      "" -> {:error, :missing_sid}
      sid -> {:ok, sid, normalize_timeout(timeout, fallback)}
    end
  end

  defp subscription_result({:error, reason}, _fallback), do: {:error, reason}
  defp subscription_result(other, _fallback), do: {:error, {:malformed_subscribe_result, other}}

  defp renewal_result({:ok, timeout}, fallback) do
    {:ok, normalize_timeout(timeout, fallback)}
  end

  defp renewal_result({:error, reason}, _fallback), do: {:error, reason}
  defp renewal_result(other, _fallback), do: {:error, {:malformed_renew_result, other}}

  defp normalize_timeout(:infinite, _fallback), do: :infinite
  defp normalize_timeout(timeout, _fallback) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout, fallback), do: fallback

  defp permanent_refusal?({:http_status, status, _body}) when status in [404, 405, 410, 501],
    do: true

  defp permanent_refusal?({:http_status, status}) when status in [404, 405, 410, 501],
    do: true

  defp permanent_refusal?(_reason), do: false

  defp terminal_initial_failure(state, reason) do
    state = state |> disable_callback() |> Map.put(:status, :failed)
    send(self(), {:terminate_failed, reason})
    state
  end

  defp fail_initial(state, reason) do
    {:noreply, terminal_initial_failure(state, reason)}
  end

  defp notify_failed(state, reason) do
    send(state.manager, {:eventing_worker_failed, state.key, self(), reason})
  end

  defp notify_stopped(state, result) do
    send(state.manager, {:eventing_worker_stopped, state.key, self(), result})
  end
end
