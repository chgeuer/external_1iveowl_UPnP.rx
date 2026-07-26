defmodule UPnP.Eventing.Manager do
  @moduledoc """
  Owns the control point's shared GENA eventing runtime.

  A canonical event subscription URL has at most one remote subscription.
  Local subscribers are monitored and share that worker. The last local
  subscriber to leave performs a graceful `UNSUBSCRIBE`.
  """

  use GenServer

  alias UPnP.Eventing.{
    CallbackServer,
    Event,
    Lifecycle,
    PropertySet,
    Subscription
  }

  alias UPnP.Network
  alias UPnP.Subscription, as: Handle

  @default_timeout 1_800_000
  @default_retry_backoff [1_000, 2_000, 5_000, 10_000]

  @type subscribe_result ::
          {:ok, Handle.t(), [UPnP.EventedProperty.t()]} | {:error, term()}

  @type callback_info :: %{
          pid: pid(),
          address: :inet.socket_address(),
          port: :inet.port_number(),
          path: String.t()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    id = Keyword.get(options, :name, {__MODULE__, make_ref()})
    %{id: id, start: {__MODULE__, :start_link, [options]}, restart: :transient, type: :worker}
  end

  @doc """
  Starts an eventing manager.

  The caller owns the manager's workers, so `:task_supervisor`,
  `:subscription_supervisor`, and `:server_supervisor` are required; a
  `UPnP.ControlPoint` passes the supervisors owned by its
  `UPnP.ControlPoint.Runtime`. Other supported options include
  `:control_point` or `:owner`, `:clock`, `:transport`,
  `:http_adapter`, `:network_adapter`, `:callback_bind`, `:callback_port`,
  `:callback_host` or `:callback_base_url`, `:subscription_timeout`, and
  `:auto_resubscribe`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name)

    options =
      Keyword.put_new_lazy(options, :owner, fn ->
        Keyword.get(options, :control_point, self())
      end)

    genserver_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, genserver_options)
  end

  @doc """
  Subscribes the caller to an event subscription URL.

  The returned last-known property snapshot and installation of the live
  subscription are atomic. Live values arrive as
  `{:upnp, subscription.ref, event}`.
  """
  @spec subscribe(GenServer.server(), URI.t() | String.t()) :: subscribe_result()
  def subscribe(manager, event_sub_url) do
    subscribe(manager, event_sub_url, self(), [])
  end

  @doc """
  Subscribes a process, or subscribes the caller with per-subscription options.

  A keyword third argument may contain `:subscriber`, `:local_address`,
  `:callback_host`, or `:facing_url`.
  """
  @spec subscribe(GenServer.server(), URI.t() | String.t(), pid() | keyword()) ::
          subscribe_result()
  def subscribe(manager, event_sub_url, subscriber) when is_pid(subscriber) do
    subscribe(manager, event_sub_url, subscriber, [])
  end

  def subscribe(manager, event_sub_url, options) when is_list(options) do
    {subscriber, options} = Keyword.pop(options, :subscriber, self())
    subscribe(manager, event_sub_url, subscriber, options)
  end

  @doc "Subscribes a process with explicit per-subscription callback options."
  @spec subscribe(GenServer.server(), URI.t() | String.t(), pid(), keyword()) ::
          subscribe_result()
  def subscribe(manager, event_sub_url, subscriber, options)
      when is_pid(subscriber) and is_list(options) do
    GenServer.call(manager, {:subscribe, event_sub_url, subscriber, options}, :infinity)
  end

  @doc "Explicitly closes an eventing subscription handle."
  @spec unsubscribe(Handle.t()) :: :ok
  def unsubscribe(%Handle{kind: :eventing} = subscription), do: Handle.close(subscription)

  @doc "Explicitly removes a local eventing subscription by reference."
  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(manager, subscription_ref) when is_reference(subscription_ref) do
    GenServer.call(manager, {:unsubscribe, subscription_ref}, :infinity)
  catch
    :exit, {:noproc, _reason} -> :ok
    :exit, {:normal, _reason} -> :ok
  end

  @doc "Gracefully stops every worker, including best-effort `UNSUBSCRIBE`s."
  @spec close(GenServer.server(), timeout()) :: :ok
  def close(manager, timeout \\ :infinity) do
    GenServer.call(manager, :close, timeout)
  catch
    :exit, {:noproc, _reason} -> :ok
    :exit, {:normal, _reason} -> :ok
  end

  @doc """
  Stops the manager abruptly.

  This releases workers and the callback listener without issuing
  `UNSUBSCRIBE`; remote finite leases are left to expire.
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(manager, timeout \\ 5_000) do
    GenServer.call(manager, :stop_abruptly, timeout)
  catch
    :exit, {:noproc, _reason} -> :ok
    :exit, {:normal, _reason} -> :ok
  end

  @doc "Returns the actual callback listener information once it has started."
  @spec callback_info(GenServer.server()) ::
          {:ok, callback_info()} | {:error, :not_started}
  def callback_info(manager), do: GenServer.call(manager, :callback_info)

  @doc "Returns the actual bound callback port, or `nil` before first use."
  @spec callback_port(GenServer.server()) :: :inet.port_number() | nil
  def callback_port(manager), do: GenServer.call(manager, :callback_port)

  @doc false
  @spec known_callback?(GenServer.server(), String.t()) :: boolean()
  def known_callback?(manager, token), do: GenServer.call(manager, {:known_callback, token})

  @doc false
  @spec deliver_callback(
          GenServer.server(),
          String.t(),
          String.t(),
          non_neg_integer(),
          binary()
        ) :: :ok | {:error, 400 | 404 | 410 | 412}
  def deliver_callback(manager, token, sid, sequence, body) do
    case PropertySet.parse(body) do
      {:ok, properties} ->
        GenServer.call(manager, {:callback, token, sid, sequence, properties})

      {:error, _parse_error} ->
        {:error, 400}
    end
  end

  @doc false
  @spec bind_sid(
          GenServer.server(),
          String.t(),
          pid(),
          String.t(),
          String.t()
        ) :: :ok | {:error, term()}
  def bind_sid(manager, key, worker, token, sid) do
    GenServer.call(manager, {:bind_sid, key, worker, token, sid})
  end

  @doc false
  @spec rotate_callback(GenServer.server(), String.t(), pid()) ::
          {:ok, String.t(), URI.t()} | {:error, term()}
  def rotate_callback(manager, key, worker) do
    GenServer.call(manager, {:rotate_callback, key, worker}, :infinity)
  end

  @doc false
  @spec disable_callback(GenServer.server(), String.t(), pid()) :: :ok
  def disable_callback(manager, key, worker) do
    GenServer.cast(manager, {:disable_callback, key, worker})
  end

  @doc false
  @spec subscription_pid(GenServer.server(), URI.t() | String.t()) :: pid() | nil
  def subscription_pid(manager, event_sub_url) do
    GenServer.call(manager, {:subscription_pid, event_sub_url})
  end

  @impl true
  def init(options) do
    with {:ok, config} <- configuration(options) do
      owner_monitor =
        case resolve_process(config.owner) do
          nil -> nil
          owner -> Process.monitor(owner)
        end

      {:ok,
       %{
         config: config,
         manager_token: token(),
         owner_monitor: owner_monitor,
         callback_server: nil,
         callback_server_monitor: nil,
         subscriptions: %{},
         tokens: %{},
         locals: %{},
         consumer_monitors: %{},
         worker_monitors: %{},
         stopping: %{},
         closing: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, _url, _subscriber, _options}, _from, %{closing: closing} = state)
      when not is_nil(closing) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:subscribe, raw_url, subscriber, call_options}, from, state) do
    with {:ok, event_url, key} <- canonical_url(raw_url) do
      case state.subscriptions[key] do
        %{status: :ready} ->
          attach_ready_consumer(key, subscriber, from, state)

        %{status: :starting} = entry ->
          pending = entry.pending ++ [%{from: from, subscriber: subscriber}]
          {:noreply, put_in(state.subscriptions[key].pending, pending)}

        nil ->
          start_shared_subscription(event_url, key, subscriber, call_options, from, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, subscription_ref}, from, state) do
    case remove_local(state, subscription_ref) do
      {:missing, state} ->
        {:reply, :ok, state}

      {:removed, _key, false, state} ->
        {:reply, :ok, state}

      {:removed, key, true, state} ->
        {:noreply, begin_worker_stop(state, key, [from])}
    end
  end

  def handle_call(:close, _from, %{closing: closing} = state) when not is_nil(closing) do
    {:reply, :ok, state}
  end

  def handle_call(:close, from, state) do
    state = begin_close(state, {:call, from})

    if close_complete?(state) do
      state = stop_callback_server(state)
      {:stop, :normal, :ok, %{state | closing: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_call(:stop_abruptly, _from, state) do
    state = abrupt_cleanup(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:callback_info, _from, %{callback_server: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:callback_info, _from, state) do
    info = CallbackServer.info(state.callback_server)

    {:reply,
     {:ok,
      %{
        pid: info.pid,
        address: info.address,
        port: info.port,
        path: "/" <> Enum.join(state.config.path_prefix, "/")
      }}, state}
  catch
    :exit, _reason -> {:reply, {:error, :not_started}, clear_callback_server(state)}
  end

  def handle_call(:callback_port, _from, %{callback_server: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:callback_port, _from, state) do
    {:reply, CallbackServer.info(state.callback_server).port, state}
  catch
    :exit, _reason -> {:reply, nil, clear_callback_server(state)}
  end

  def handle_call({:known_callback, callback_token}, _from, state) do
    {:reply, Map.has_key?(state.tokens, callback_token), state}
  end

  def handle_call({:callback, callback_token, sid, sequence, properties}, _from, state) do
    reply =
      with {:ok, key} <- fetch_token(state, callback_token),
           {:ok, entry} <- fetch_subscription(state, key),
           :ok <- matching_sid(entry.sid, sid),
           true <- Process.alive?(entry.worker) do
        Subscription.notify(entry.worker, callback_token, sid, sequence, properties)
        :ok
      else
        {:error, status} when is_integer(status) -> {:error, status}
        false -> {:error, 410}
      end

    {:reply, reply, state}
  end

  def handle_call({:bind_sid, key, worker, callback_token, sid}, _from, state) do
    case state.subscriptions[key] do
      %{worker: ^worker, token: ^callback_token} ->
        {:reply, :ok, put_in(state.subscriptions[key].sid, sid)}

      _other ->
        {:reply, {:error, :stale_subscription}, state}
    end
  end

  def handle_call({:rotate_callback, key, worker}, _from, state) do
    case state.subscriptions[key] do
      %{worker: ^worker} = entry ->
        with {:ok, state} <- ensure_callback_server(state) do
          callback_token = token()
          callback_url = callback_url(entry.origin, state, callback_token)

          tokens =
            state.tokens
            |> maybe_delete_token(entry.token)
            |> Map.put(callback_token, key)

          entry = %{entry | token: callback_token, sid: nil}

          state = %{
            state
            | tokens: tokens,
              subscriptions: Map.put(state.subscriptions, key, entry)
          }

          {:reply, {:ok, callback_token, callback_url}, state}
        else
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      _other ->
        {:reply, {:error, :stale_subscription}, state}
    end
  end

  def handle_call({:subscription_pid, raw_url}, _from, state) do
    pid =
      with {:ok, _uri, key} <- canonical_url(raw_url),
           %{worker: worker} <- state.subscriptions[key] do
        worker
      else
        _other -> nil
      end

    {:reply, pid, state}
  end

  @impl true
  def handle_cast({:disable_callback, key, worker}, state) do
    state =
      case state.subscriptions[key] do
        %{worker: ^worker} = entry ->
          subscriptions =
            Map.put(state.subscriptions, key, %{entry | token: nil, sid: nil})

          %{
            state
            | subscriptions: subscriptions,
              tokens: maybe_delete_token(state.tokens, entry.token)
          }

        _other ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:eventing_worker_ready, key, worker, lifecycle}, state) do
    case state.subscriptions[key] do
      %{worker: ^worker, status: :starting} = entry ->
        state = put_in(state.subscriptions[key], %{entry | status: :ready, pending: []})

        {state, local_refs} =
          Enum.reduce(entry.pending, {state, []}, fn pending, {acc, refs} ->
            if Process.alive?(pending.subscriber) and Process.alive?(elem(pending.from, 0)) do
              {handle, acc} = add_local(acc, key, pending.subscriber)
              GenServer.reply(pending.from, {:ok, handle, entry.snapshot})
              {acc, [handle.ref | refs]}
            else
              if Process.alive?(elem(pending.from, 0)) do
                GenServer.reply(pending.from, {:error, :subscriber_not_alive})
              end

              {acc, refs}
            end
          end)

        Enum.each(Enum.reverse(local_refs), &send_local(state, &1, lifecycle))

        if local_refs == [] do
          {:noreply, begin_worker_stop(state, key, [])}
        else
          {:noreply, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:eventing_worker_failed, key, worker, reason}, state) do
    state =
      case state.subscriptions[key] do
        %{worker: ^worker, status: :starting} ->
          fail_starting_subscription(state, key, reason)

        %{worker: ^worker} ->
          broadcast_key(state, key, lifecycle(state, :lost, reason: reason))

        _other ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:eventing_worker_event, key, worker, event}, state) do
    state =
      case state.subscriptions[key] do
        %{worker: ^worker} = entry ->
          state =
            case event do
              %Event{snapshot: snapshot} ->
                put_in(state.subscriptions[key], %{entry | snapshot: snapshot})

              %Lifecycle{
                kind: kind
              }
              when kind in [:lost, :resubscribing, :retry_exhausted, :subscription_refused] ->
                put_in(state.subscriptions[key], %{entry | snapshot: []})

              %Lifecycle{} ->
                state
            end

          broadcast_key(state, key, event)

        _other ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:eventing_worker_stopped, _key, worker, _result}, state) do
    state = finish_worker_stop(state, worker)
    finish_close_or_continue(state)
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{owner_monitor: monitor} = state
      ) do
    {:stop, :normal, abrupt_cleanup(%{state | owner_monitor: nil})}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{callback_server_monitor: monitor} = state
      ) do
    state = clear_callback_server(state)

    if is_nil(state.closing) do
      Enum.each(state.subscriptions, fn {_key, entry} ->
        Subscription.callback_server_down(entry.worker, reason)
      end)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.consumer_monitors, monitor) ->
        subscription_ref = state.consumer_monitors[monitor]

        case remove_local(state, subscription_ref, false) do
          {:removed, key, true, state} ->
            {:noreply, begin_worker_stop(state, key, [])}

          {_result, state} ->
            {:noreply, state}
        end

      Map.has_key?(state.worker_monitors, monitor) ->
        {key, worker} = state.worker_monitors[monitor]
        state = %{state | worker_monitors: Map.delete(state.worker_monitors, monitor)}

        state =
          if Map.has_key?(state.stopping, worker) do
            finish_worker_stop(state, worker)
          else
            unexpected_worker_exit(state, key, worker, reason)
          end

        finish_close_or_continue(state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = abrupt_cleanup(state)
    :ok
  end

  defp configuration(options) do
    timeout =
      Keyword.get(options, :subscription_timeout) ||
        Keyword.get(options, :event_subscription_timeout) ||
        @default_timeout

    callback_port =
      Keyword.get(options, :callback_port) ||
        Keyword.get(options, :event_callback_port) ||
        0

    max_body_bytes =
      Keyword.get(options, :max_callback_body_bytes) ||
        Keyword.get(options, :max_document_bytes) ||
        1_048_576

    operation_timeout =
      Keyword.get(options, :operation_timeout) ||
        Keyword.get(options, :action_timeout) ||
        30_000

    retry_backoff = Keyword.get(options, :retry_backoff, @default_retry_backoff)
    auto_resubscribe = Keyword.get(options, :auto_resubscribe, true)
    max_early_notifications = Keyword.get(options, :max_early_notifications, 32)
    callback_acceptors = Keyword.get(options, :callback_acceptors, 2)
    task_supervisor = Keyword.get(options, :task_supervisor)
    subscription_supervisor = Keyword.get(options, :subscription_supervisor)
    server_supervisor = Keyword.get(options, :server_supervisor)

    callback_scheme =
      case Keyword.get(options, :callback_scheme, "http") do
        scheme when is_binary(scheme) -> String.downcase(scheme)
        scheme when is_atom(scheme) -> scheme |> Atom.to_string() |> String.downcase()
        _other -> :invalid
      end

    callback_base_url =
      options
      |> Keyword.get(
        :callback_base_url,
        Keyword.get(options, :callback_facing_url, Keyword.get(options, :callback_url))
      )
      |> parse_optional_uri()

    callback_path =
      Keyword.get_lazy(options, :callback_path, fn ->
        case callback_base_url do
          %URI{path: path} when is_binary(path) and path not in ["", "/"] -> path
          _other -> "/upnp/events"
        end
      end)

    cond do
      not is_integer(timeout) or timeout <= 0 ->
        {:error, :invalid_subscription_timeout}

      not is_integer(callback_port) or callback_port not in 0..65_535 ->
        {:error, :invalid_callback_port}

      not is_integer(max_body_bytes) or max_body_bytes <= 0 ->
        {:error, :invalid_max_callback_body_bytes}

      not is_integer(operation_timeout) or operation_timeout <= 0 ->
        {:error, :invalid_operation_timeout}

      not is_list(retry_backoff) or
          not Enum.all?(retry_backoff, &(is_integer(&1) and &1 >= 0)) ->
        {:error, :invalid_retry_backoff}

      callback_base_url == :error ->
        {:error, :invalid_callback_base_url}

      callback_scheme not in ["http", "https"] ->
        {:error, :invalid_callback_scheme}

      not is_binary(callback_path) ->
        {:error, :invalid_callback_path}

      not is_boolean(auto_resubscribe) ->
        {:error, :invalid_auto_resubscribe}

      not is_integer(max_early_notifications) or max_early_notifications < 0 ->
        {:error, :invalid_max_early_notifications}

      not is_integer(callback_acceptors) or callback_acceptors <= 0 ->
        {:error, :invalid_callback_acceptors}

      is_nil(task_supervisor) ->
        {:error, :missing_task_supervisor}

      is_nil(subscription_supervisor) ->
        {:error, :missing_subscription_supervisor}

      is_nil(server_supervisor) ->
        {:error, :missing_server_supervisor}

      true ->
        transport_options =
          options
          |> Keyword.get(:transport_options, [])
          |> maybe_put_http_adapter(options)

        {:ok,
         %{
           owner: Keyword.get(options, :owner),
           identity: Keyword.get(options, :control_point, Keyword.get(options, :owner)),
           clock: Keyword.get(options, :clock, UPnP.Clock.System),
           transport:
             Keyword.get(
               options,
               :transport,
               Keyword.get(options, :gena_transport, UPnP.Eventing.Transport.HTTP)
             ),
           transport_options: transport_options,
           callback_bind:
             Keyword.get(
               options,
               :callback_bind,
               Keyword.get(
                 options,
                 :callback_bind_address,
                 Keyword.get(options, :callback_ip, :any)
               )
             ),
           callback_port: callback_port,
           callback_host:
             Keyword.get(
               options,
               :callback_host,
               Keyword.get(
                 options,
                 :callback_facing_host,
                 Keyword.get(options, :callback_address)
               )
             ),
           callback_scheme: callback_scheme,
           callback_base_url: callback_base_url,
           path_prefix: path_segments(callback_path),
           max_body_bytes: max_body_bytes,
           operation_timeout: operation_timeout,
           callback_acceptors: callback_acceptors,
           subscription_timeout: timeout,
           auto_resubscribe: auto_resubscribe,
           retry_backoff: retry_backoff,
           max_early_notifications: max_early_notifications,
           task_supervisor: task_supervisor,
           subscription_supervisor: subscription_supervisor,
           server_supervisor: server_supervisor,
           network_adapter: Keyword.get(options, :network_adapter, UPnP.Network.System)
         }}
    end
  end

  defp maybe_put_http_adapter(transport_options, options) do
    case Keyword.fetch(options, :http_adapter) do
      {:ok, adapter} ->
        Keyword.put(transport_options, :http_adapter, adapter)

      :error ->
        Keyword.put_new(transport_options, :http_adapter, {UPnP.HTTP.Finch, [name: UPnP.Finch]})
    end
  end

  defp parse_optional_uri(nil), do: nil
  defp parse_optional_uri(%URI{} = uri), do: normalize_facing_uri(uri)

  defp parse_optional_uri(value) when is_binary(value),
    do: value |> URI.parse() |> normalize_facing_uri()

  defp parse_optional_uri(_value), do: :error

  defp normalize_facing_uri(%URI{scheme: scheme, host: host} = uri)
       when is_binary(scheme) and is_binary(host) and host != "" do
    scheme = String.downcase(scheme)

    if scheme in ["http", "https"] do
      %{uri | scheme: scheme, authority: nil, userinfo: nil, host: String.downcase(host)}
    else
      :error
    end
  end

  defp normalize_facing_uri(_uri), do: :error

  defp path_segments(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [] -> ["upnp", "events"]
      segments -> segments
    end
  end

  defp start_shared_subscription(event_url, key, subscriber, call_options, from, state) do
    with {:ok, state} <- ensure_callback_server(state),
         {:ok, origin} <- callback_origin(event_url, call_options, state) do
      callback_token = token()
      callback_url = callback_url(origin, state, callback_token)

      worker_options = [
        manager: self(),
        key: key,
        event_url: event_url,
        callback_token: callback_token,
        callback_url: callback_url,
        clock: state.config.clock,
        transport: state.config.transport,
        transport_options: state.config.transport_options,
        task_supervisor: state.config.task_supervisor,
        subscription_timeout: state.config.subscription_timeout,
        operation_timeout: state.config.operation_timeout,
        auto_resubscribe: state.config.auto_resubscribe,
        retry_backoff: state.config.retry_backoff,
        max_early_notifications: state.config.max_early_notifications
      ]

      child_spec = Supervisor.child_spec({Subscription, worker_options}, restart: :temporary)

      case start_dynamic_child(state.config.subscription_supervisor, child_spec) do
        {:ok, worker} ->
          monitor = Process.monitor(worker)

          entry = %{
            worker: worker,
            monitor: monitor,
            event_url: event_url,
            origin: origin,
            token: callback_token,
            sid: nil,
            status: :starting,
            pending: [%{from: from, subscriber: subscriber}],
            consumers: MapSet.new(),
            snapshot: []
          }

          state = %{
            state
            | subscriptions: Map.put(state.subscriptions, key, entry),
              tokens: Map.put(state.tokens, callback_token, key),
              worker_monitors: Map.put(state.worker_monitors, monitor, {key, worker})
          }

          {:noreply, state}

        {:error, reason} ->
          {:reply, {:error, {:subscription_start_failed, reason}}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_callback_server(%{callback_server: server} = state) when is_pid(server) do
    if Process.alive?(server),
      do: {:ok, state},
      else: ensure_callback_server(clear_callback_server(state))
  end

  defp ensure_callback_server(state) do
    plug_options = [
      manager: self(),
      manager_token: state.manager_token,
      path_prefix: state.config.path_prefix,
      max_body_bytes: state.config.max_body_bytes
    ]

    server_options = [
      manager: self(),
      bind: state.config.callback_bind,
      port: state.config.callback_port,
      acceptors: state.config.callback_acceptors,
      plug_options: plug_options
    ]

    child_spec = Supervisor.child_spec({CallbackServer, server_options}, restart: :temporary)

    case start_dynamic_child(state.config.server_supervisor, child_spec) do
      {:ok, server} ->
        monitor = Process.monitor(server)
        {:ok, %{state | callback_server: server, callback_server_monitor: monitor}}

      {:error, reason} ->
        {:error, {:callback_server_start_failed, reason}, state}
    end
  end

  defp callback_origin(event_url, call_options, state) do
    facing_url =
      Keyword.get(call_options, :facing_url) ||
        Keyword.get(call_options, :callback_base_url) ||
        state.config.callback_base_url

    if facing_url do
      case parse_optional_uri(facing_url) do
        %URI{} = uri -> {:ok, uri}
        _other -> {:error, :invalid_facing_url}
      end
    else
      routed_callback_origin(event_url, call_options, state)
    end
  end

  defp routed_callback_origin(event_url, call_options, state) do
    with {:ok, info} <- callback_server_info(state),
         {:ok, host} <- callback_host(event_url, call_options, state) do
      {:ok,
       %URI{
         scheme: state.config.callback_scheme,
         host: host,
         port: info.port
       }}
    end
  end

  defp callback_server_info(state) do
    try do
      {:ok, CallbackServer.info(state.callback_server)}
    catch
      :exit, reason -> {:error, {:callback_server_unavailable, reason}}
    end
  end

  defp callback_host(event_url, call_options, state) do
    explicit =
      Keyword.get(call_options, :callback_host) ||
        Keyword.get(call_options, :local_address) ||
        state.config.callback_host

    cond do
      explicit not in [nil, :auto] ->
        normalize_host(explicit)

      usable_bind?(state.config.callback_bind) ->
        normalize_host(state.config.callback_bind)

      true ->
        route_address(state.config.network_adapter, event_url)
    end
  end

  defp route_address(adapter, event_url) do
    case Network.local_address_for(adapter, event_url) do
      {:ok, {0, 0, 0, 0}} ->
        {:error, {:callback_address_unavailable, :wildcard_address}}

      {:ok, address} ->
        normalize_host(address)

      {:error, reason} ->
        {:error, {:callback_address_unavailable, reason}}
    end
  end

  defp normalize_host(address) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, reason} -> {:error, {:invalid_callback_host, reason}}
      characters -> {:ok, List.to_string(characters)}
    end
  end

  defp normalize_host(:loopback), do: {:ok, "127.0.0.1"}

  defp normalize_host(host) when is_binary(host) do
    case String.trim(host) do
      "" -> {:error, :invalid_callback_host}
      trimmed -> {:ok, String.trim(trimmed, "[]")}
    end
  end

  defp normalize_host(_host), do: {:error, :invalid_callback_host}

  defp usable_bind?({0, 0, 0, 0}), do: false
  defp usable_bind?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp usable_bind?(:loopback), do: true
  defp usable_bind?(address) when is_tuple(address), do: true
  defp usable_bind?(_address), do: false

  defp callback_url(origin, state, callback_token) do
    path =
      "/" <>
        Enum.join(
          state.config.path_prefix ++ [state.manager_token, callback_token],
          "/"
        )

    %{origin | path: path, query: nil, fragment: nil, userinfo: nil}
  end

  defp attach_ready_consumer(key, subscriber, _from, state) do
    snapshot = state.subscriptions[key].snapshot
    {handle, state} = add_local(state, key, subscriber)
    {:reply, {:ok, handle, snapshot}, state}
  end

  defp add_local(state, key, subscriber) do
    subscription_ref = make_ref()
    monitor = Process.monitor(subscriber)
    handle = %Handle{server: self(), ref: subscription_ref, kind: :eventing}

    local = %{pid: subscriber, monitor: monitor, key: key}
    entry = state.subscriptions[key]
    entry = %{entry | consumers: MapSet.put(entry.consumers, subscription_ref)}

    state = %{
      state
      | subscriptions: Map.put(state.subscriptions, key, entry),
        locals: Map.put(state.locals, subscription_ref, local),
        consumer_monitors: Map.put(state.consumer_monitors, monitor, subscription_ref)
    }

    {handle, state}
  end

  defp remove_local(state, subscription_ref, demonitor? \\ true) do
    case Map.pop(state.locals, subscription_ref) do
      {nil, _locals} ->
        {:missing, state}

      {local, locals} ->
        if demonitor?, do: Process.demonitor(local.monitor, [:flush])

        consumer_monitors = Map.delete(state.consumer_monitors, local.monitor)

        case state.subscriptions[local.key] do
          nil ->
            {:removed, local.key, false,
             %{state | locals: locals, consumer_monitors: consumer_monitors}}

          entry ->
            consumers = MapSet.delete(entry.consumers, subscription_ref)
            entry = %{entry | consumers: consumers}

            state = %{
              state
              | locals: locals,
                consumer_monitors: consumer_monitors,
                subscriptions: Map.put(state.subscriptions, local.key, entry)
            }

            {:removed, local.key, MapSet.size(consumers) == 0, state}
        end
    end
  end

  defp begin_worker_stop(state, key, waiters) do
    case Map.pop(state.subscriptions, key) do
      {nil, _subscriptions} ->
        Enum.each(waiters, &GenServer.reply(&1, :ok))
        state

      {entry, subscriptions} ->
        Enum.each(entry.pending, &GenServer.reply(&1.from, {:error, :closed}))

        tokens = maybe_delete_token(state.tokens, entry.token)
        Subscription.graceful_stop(entry.worker)

        stopping_entry = %{
          key: key,
          monitor: entry.monitor,
          waiters: waiters
        }

        %{
          state
          | subscriptions: subscriptions,
            tokens: tokens,
            stopping: Map.put(state.stopping, entry.worker, stopping_entry)
        }
    end
  end

  defp finish_worker_stop(state, worker) do
    case Map.pop(state.stopping, worker) do
      {nil, _stopping} ->
        state

      {entry, stopping} ->
        Enum.each(entry.waiters, &GenServer.reply(&1, :ok))
        Process.demonitor(entry.monitor, [:flush])

        %{
          state
          | stopping: stopping,
            worker_monitors: Map.delete(state.worker_monitors, entry.monitor)
        }
    end
  end

  defp fail_starting_subscription(state, key, reason) do
    case Map.pop(state.subscriptions, key) do
      {nil, _subscriptions} ->
        state

      {entry, subscriptions} ->
        Enum.each(entry.pending, &GenServer.reply(&1.from, {:error, reason}))

        %{
          state
          | subscriptions: subscriptions,
            tokens: maybe_delete_token(state.tokens, entry.token)
        }
    end
  end

  defp unexpected_worker_exit(state, key, worker, reason) do
    case state.subscriptions[key] do
      %{worker: ^worker} = entry ->
        event = lifecycle(state, :lost, sid: entry.sid, reason: {:worker_exit, reason})
        state = broadcast_key(state, key, event)
        Enum.each(entry.pending, &GenServer.reply(&1.from, {:error, {:worker_exit, reason}}))

        state
        |> remove_key_locals(key)
        |> then(fn state ->
          %{
            state
            | subscriptions: Map.delete(state.subscriptions, key),
              tokens: maybe_delete_token(state.tokens, entry.token)
          }
        end)

      _other ->
        state
    end
  end

  defp remove_key_locals(state, key) do
    refs =
      state.locals
      |> Enum.filter(fn {_ref, local} -> local.key == key end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(refs, state, fn ref, acc ->
      case remove_local(acc, ref) do
        {_status, _key, _last, acc} -> acc
        {_status, acc} -> acc
      end
    end)
  end

  defp begin_close(state, closing) do
    state = %{state | closing: closing}

    state =
      state.locals
      |> Map.keys()
      |> Enum.reduce(state, fn ref, acc ->
        case remove_local(acc, ref) do
          {_status, _key, _last, acc} -> acc
          {_status, acc} -> acc
        end
      end)

    state.subscriptions
    |> Map.keys()
    |> Enum.reduce(state, &begin_worker_stop(&2, &1, []))
  end

  defp close_complete?(state) do
    map_size(state.subscriptions) == 0 and map_size(state.stopping) == 0
  end

  defp finish_close_or_continue(state) do
    if not is_nil(state.closing) and close_complete?(state) do
      state = stop_callback_server(state)

      case state.closing do
        {:call, from} -> GenServer.reply(from, :ok)
        :owner -> :ok
      end

      {:stop, :normal, %{state | closing: nil}}
    else
      {:noreply, state}
    end
  end

  defp abrupt_cleanup(state) do
    Enum.each(state.subscriptions, fn {_key, entry} ->
      terminate_child(state.config.subscription_supervisor, entry.worker)
    end)

    Enum.each(state.stopping, fn {worker, _entry} ->
      terminate_child(state.config.subscription_supervisor, worker)
    end)

    stop_callback_server(%{state | subscriptions: %{}, stopping: %{}, tokens: %{}})
  end

  defp stop_callback_server(%{callback_server: nil} = state), do: state

  defp stop_callback_server(state) do
    if state.callback_server_monitor do
      Process.demonitor(state.callback_server_monitor, [:flush])
    end

    terminate_child(state.config.server_supervisor, state.callback_server)
    %{state | callback_server: nil, callback_server_monitor: nil}
  end

  defp clear_callback_server(state) do
    if state.callback_server_monitor do
      Process.demonitor(state.callback_server_monitor, [:flush])
    end

    %{state | callback_server: nil, callback_server_monitor: nil}
  end

  defp terminate_child(supervisor, child) when is_pid(child) do
    try do
      DynamicSupervisor.terminate_child(supervisor, child)
    catch
      :exit, _reason -> :ok
    end
  end

  defp start_dynamic_child(supervisor, child_spec) do
    try do
      DynamicSupervisor.start_child(supervisor, child_spec)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp broadcast_key(state, key, event) do
    case state.subscriptions[key] do
      nil ->
        state

      entry ->
        Enum.each(entry.consumers, &send_local(state, &1, event))
        state
    end
  end

  defp send_local(state, subscription_ref, event) do
    case state.locals[subscription_ref] do
      %{pid: pid} -> send(pid, {:upnp, subscription_ref, event})
      nil -> :ok
    end
  end

  defp lifecycle(state, kind, fields) do
    struct!(
      Lifecycle,
      Keyword.merge([kind: kind, occurred_at: UPnP.Clock.utc_now(state.config.clock)], fields)
    )
  end

  defp fetch_token(state, callback_token) do
    case state.tokens[callback_token] do
      nil -> {:error, 404}
      key -> {:ok, key}
    end
  end

  defp fetch_subscription(state, key) do
    case state.subscriptions[key] do
      nil -> {:error, 410}
      entry -> {:ok, entry}
    end
  end

  defp matching_sid(nil, sid) when is_binary(sid) and sid != "", do: :ok
  defp matching_sid(sid, sid), do: :ok
  defp matching_sid(_expected, _actual), do: {:error, 412}

  defp maybe_delete_token(tokens, nil), do: tokens
  defp maybe_delete_token(tokens, callback_token), do: Map.delete(tokens, callback_token)

  defp canonical_url(%URI{} = uri), do: normalize_url(uri)

  defp canonical_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> normalize_url()
  end

  defp canonical_url(_url), do: {:error, :invalid_event_sub_url}

  defp normalize_url(%URI{scheme: scheme, host: host} = uri)
       when is_binary(scheme) and is_binary(host) and host != "" do
    scheme = String.downcase(scheme)
    host = String.downcase(host)

    if scheme in ["http", "https"] do
      port =
        if uri.port == URI.default_port(scheme) do
          nil
        else
          uri.port
        end

      normalized = %{
        uri
        | scheme: scheme,
          authority: nil,
          userinfo: nil,
          host: host,
          port: port,
          path: if(uri.path in [nil, ""], do: "/", else: uri.path),
          fragment: nil
      }

      {:ok, normalized, URI.to_string(normalized)}
    else
      {:error, :invalid_event_sub_url}
    end
  end

  defp normalize_url(_uri), do: {:error, :invalid_event_sub_url}

  defp resolve_process(pid) when is_pid(pid), do: pid

  defp resolve_process(server) do
    try do
      GenServer.whereis(server)
    catch
      :exit, _reason -> nil
    end
  end

  defp token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
