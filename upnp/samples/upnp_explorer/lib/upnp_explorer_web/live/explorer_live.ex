defmodule UpnpExplorerWeb.ExplorerLive do
  @moduledoc "Live roster, device inspector, and service event viewer."

  use UpnpExplorerWeb, :live_view

  import UpnpExplorerWeb.ExplorerComponents

  alias UPnP.{Service, Subscription}
  alias UPnP.Eventing.{Event, Lifecycle}
  alias UpnpExplorer.{Activity, DeviceView, EventView, Explorer, ServiceView}

  @scan_help_delay 5_000
  @confirmation_ttl_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Explorer.snapshot()

    if connected?(socket) do
      :ok = Explorer.subscribe()
      Process.send_after(self(), :show_scan_help, @scan_help_delay)
    end

    socket =
      socket
      |> assign(
        page_title: "Devices",
        status: snapshot.status,
        filter: "",
        filter_form: to_form(%{"q" => ""}, as: :filter),
        selected_device: nil,
        selected_service_id: nil,
        service_detail: nil,
        service_loading?: false,
        service_error: nil,
        watch_subscription: nil,
        watch_ref: nil,
        watch_loading?: false,
        watch_error: nil,
        action_operation: nil,
        probing?: false,
        show_scan_help?: false
      )
      |> stream_configure(:devices, dom_id: & &1.id)
      |> stream(:devices, snapshot.devices)
      |> stream_configure(:rail_activity, dom_id: &"rail-#{&1.id}")
      |> stream(:rail_activity, snapshot.activities |> changes_only() |> Enum.take(12))
      |> stream_configure(:device_nodes, dom_id: & &1.id)
      |> stream(:device_nodes, [])
      |> stream_configure(:services, dom_id: & &1.id)
      |> stream(:services, [])
      |> stream_configure(:service_actions, dom_id: & &1.id)
      |> stream(:service_actions, [])
      |> stream_configure(:state_variables, dom_id: & &1.id)
      |> stream(:state_variables, [])
      |> stream_configure(:service_events, dom_id: & &1.id)
      |> stream(:service_events, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_device(socket, params["device_id"])}
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"q" => query}}, socket) do
    devices = Explorer.list_devices(query)

    {:noreply,
     socket
     |> assign(
       filter: query,
       filter_form: to_form(%{"q" => query}, as: :filter)
     )
     |> stream(:devices, devices, reset: true)}
  end

  def handle_event("probe", _params, socket) do
    {:noreply,
     socket
     |> assign(:probing?, true)
     |> start_async(:probe, &Explorer.probe/0)}
  end

  def handle_event("inspect-service", %{"id" => service_id}, socket) do
    socket =
      socket
      |> stop_watch()
      |> assign(
        selected_service_id: service_id,
        service_detail: nil,
        service_loading?: true,
        service_error: nil,
        watch_error: nil,
        action_operation: nil
      )
      |> stream(:service_actions, [], reset: true)
      |> stream(:state_variables, [], reset: true)
      |> stream(:service_events, [], reset: true)

    device_id = socket.assigns.selected_device.id

    {:noreply,
     start_async(socket, {:service_detail, service_id}, fn ->
       Explorer.service_detail(device_id, service_id)
     end)}
  end

  def handle_event("close-service", _params, socket) do
    {:noreply,
     socket
     |> stop_watch()
     |> assign(
       selected_service_id: nil,
       service_detail: nil,
       service_loading?: false,
       service_error: nil,
       watch_error: nil,
       action_operation: nil
     )
     |> stream(:service_actions, [], reset: true)
     |> stream(:state_variables, [], reset: true)
     |> stream(:service_events, [], reset: true)}
  end

  def handle_event(
        "toggle-watch",
        _params,
        %{assigns: %{watch_subscription: subscription}} = socket
      )
      when not is_nil(subscription) do
    {:noreply, stop_watch(socket)}
  end

  def handle_event("toggle-watch", _params, socket) do
    owner = self()
    device_id = socket.assigns.selected_device.id
    service_id = socket.assigns.selected_service_id

    {:noreply,
     socket
     |> assign(watch_loading?: true, watch_error: nil)
     |> start_async({:watch_service, service_id}, fn ->
       with {:ok, {service, _summary}} <- Explorer.service(device_id, service_id),
            {:ok, subscription, snapshot} <- Service.subscribe(service, subscriber: owner) do
         {:ok, subscription, snapshot}
       end
     end)}
  end

  def handle_event("submit-action", params, socket) do
    action_name = params["action"]
    arguments = Map.get(params, "arguments", %{})

    cond do
      not is_nil(socket.assigns.action_operation) ->
        {:noreply,
         put_flash(socket, :error, "Finish the current action before starting another.")}

      not valid_arguments?(arguments) ->
        {:noreply, put_flash(socket, :error, "The action arguments are invalid.")}

      true ->
        case find_action(socket, action_name) do
          {:ok, action} ->
            if action.policy.confirmation_required? do
              {:noreply, prepare_confirmation(socket, action, arguments)}
            else
              {:noreply, start_action(socket, action, arguments)}
            end

          :error ->
            {:noreply, put_flash(socket, :error, "That action is not available.")}
        end
    end
  end

  def handle_event("confirm-action", %{"action" => action_name}, socket) do
    case socket.assigns.action_operation do
      %{
        phase: :confirming,
        action_name: ^action_name,
        service_id: service_id,
        arguments: arguments,
        prepared_at: prepared_at
      }
      when service_id == socket.assigns.selected_service_id ->
        case find_action(socket, action_name) do
          {:ok, action} ->
            if confirmation_fresh?(prepared_at) do
              {:noreply, start_action(socket, action, arguments)}
            else
              {:noreply,
               socket
               |> assign(:action_operation, nil)
               |> update_action(action_name,
                 operation_status: :error,
                 operation_error: "Confirmation expired. Review the action again.",
                 pending_arguments: %{}
               )}
            end

          :error ->
            {:noreply, put_flash(socket, :error, "That action is no longer available.")}
        end

      _operation ->
        {:noreply, put_flash(socket, :error, "That confirmation is no longer valid.")}
    end
  end

  def handle_event("cancel-action", %{"action" => action_name}, socket) do
    case socket.assigns.action_operation do
      %{phase: :confirming, action_name: ^action_name} ->
        {:noreply,
         socket
         |> assign(:action_operation, nil)
         |> update_action(action_name,
           operation_status: :idle,
           operation_result: nil,
           operation_error: nil,
           pending_arguments: %{}
         )}

      _operation ->
        {:noreply, put_flash(socket, :error, "That confirmation is no longer valid.")}
    end
  end

  @impl true
  def handle_async(:probe, {:ok, :ok}, socket) do
    {:noreply, assign(socket, :probing?, false)}
  end

  def handle_async(:probe, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:probing?, false)
     |> put_flash(:error, "Search failed: #{format_reason(reason)}")}
  end

  def handle_async(:probe, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:probing?, false)
     |> put_flash(:error, "Search task stopped: #{format_reason(reason)}")}
  end

  def handle_async(
        {:service_detail, service_id},
        {:ok, {:ok, detail}},
        %{assigns: %{selected_service_id: service_id}} = socket
      ) do
    actions = Enum.map(detail.actions, &prepare_action_form/1)
    detail = %{detail | actions: actions}

    {:noreply,
     socket
     |> assign(
       service_detail: detail,
       service_loading?: false,
       service_error: nil
     )
     |> stream(:service_actions, detail.actions, reset: true)
     |> stream(:state_variables, detail.state_variables, reset: true)}
  end

  def handle_async(
        {:service_detail, service_id},
        {:ok, {:error, reason}},
        %{assigns: %{selected_service_id: service_id}} = socket
      ) do
    {:noreply,
     assign(socket,
       service_loading?: false,
       service_error: format_reason(reason)
     )}
  end

  def handle_async(
        {:service_detail, service_id},
        {:exit, reason},
        %{assigns: %{selected_service_id: service_id}} = socket
      ) do
    {:noreply,
     assign(socket,
       service_loading?: false,
       service_error: format_reason(reason)
     )}
  end

  def handle_async({:service_detail, _service_id}, _result, socket), do: {:noreply, socket}

  def handle_async(
        {:watch_service, service_id},
        {:ok, {:ok, subscription, snapshot}},
        %{assigns: %{selected_service_id: service_id}} = socket
      ) do
    events = EventView.from_snapshot(snapshot)

    {:noreply,
     socket
     |> assign(
       watch_subscription: subscription,
       watch_ref: subscription.ref,
       watch_loading?: false,
       watch_error: nil
     )
     |> stream(:service_events, events, reset: true)}
  end

  def handle_async(
        {:watch_service, service_id},
        {:ok, {:error, reason}},
        %{assigns: %{selected_service_id: service_id}} = socket
      ) do
    {:noreply,
     assign(socket,
       watch_loading?: false,
       watch_error: format_reason(reason)
     )}
  end

  def handle_async(
        {:watch_service, service_id},
        {:exit, reason},
        %{assigns: %{selected_service_id: service_id}} = socket
      ) do
    {:noreply,
     assign(socket,
       watch_loading?: false,
       watch_error: format_reason(reason)
     )}
  end

  def handle_async({:watch_service, _service_id}, {:ok, {:ok, subscription, _snapshot}}, socket) do
    Subscription.close(subscription)
    {:noreply, socket}
  end

  def handle_async({:watch_service, _service_id}, _result, socket), do: {:noreply, socket}

  def handle_async(
        {:invoke_action, service_id, action_name},
        {:ok, {:ok, result}},
        %{
          assigns: %{
            selected_service_id: service_id,
            action_operation: %{
              phase: :running,
              service_id: service_id,
              action_name: action_name
            }
          }
        } = socket
      ) do
    case find_action(socket, action_name) do
      {:ok, action} ->
        {:noreply,
         socket
         |> assign(:action_operation, nil)
         |> update_action(action_name,
           operation_status: :success,
           operation_result: ServiceView.action_result(action, result),
           operation_error: nil,
           pending_arguments: %{}
         )}

      :error ->
        {:noreply, assign(socket, :action_operation, nil)}
    end
  end

  def handle_async(
        {:invoke_action, service_id, action_name},
        {:ok, {:error, reason}},
        %{
          assigns: %{
            selected_service_id: service_id,
            action_operation: %{
              phase: :running,
              service_id: service_id,
              action_name: action_name
            }
          }
        } = socket
      ) do
    {:noreply,
     socket
     |> assign(:action_operation, nil)
     |> update_action(action_name,
       operation_status: :error,
       operation_result: nil,
       operation_error: format_reason(reason),
       pending_arguments: %{}
     )}
  end

  def handle_async(
        {:invoke_action, service_id, action_name},
        {:exit, reason},
        %{
          assigns: %{
            selected_service_id: service_id,
            action_operation: %{
              phase: :running,
              service_id: service_id,
              action_name: action_name
            }
          }
        } = socket
      ) do
    {:noreply,
     socket
     |> assign(:action_operation, nil)
     |> update_action(action_name,
       operation_status: :error,
       operation_result: nil,
       operation_error: "Action task stopped: #{format_reason(reason)}",
       pending_arguments: %{}
     )}
  end

  def handle_async({:invoke_action, _service_id, _action_name}, _result, socket),
    do: {:noreply, socket}

  @impl true
  def handle_info({:explorer_device_upserted, device}, socket) do
    socket =
      if device.id == selected_device_id(socket) do
        socket
        |> assign(:selected_device, device)
        |> stream(:device_nodes, device.nodes, reset: true)
        |> stream(:services, device.services, reset: true)
      else
        socket
      end

    socket =
      if DeviceView.matches?(device, socket.assigns.filter) do
        stream_insert(socket, :devices, device)
      else
        stream_delete_by_dom_id(socket, :devices, device.id)
      end

    {:noreply, assign(socket, :show_scan_help?, false)}
  end

  def handle_info({:explorer_device_removed, device_id}, socket) do
    socket = stream_delete_by_dom_id(socket, :devices, device_id)

    socket =
      if device_id == selected_device_id(socket) do
        socket
        |> stop_watch()
        |> put_flash(:info, "The selected device left the network.")
        |> push_patch(to: ~p"/")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:explorer_activity_upserted, %Activity{} = activity}, socket) do
    if Activity.matches?(activity, :changes) do
      {:noreply, stream_insert(socket, :rail_activity, activity, at: 0, limit: 12)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:explorer_status, status}, socket) do
    {:noreply, assign(socket, :status, status)}
  end

  def handle_info(
        {:upnp, ref, %Event{} = event},
        %{assigns: %{watch_ref: ref}} = socket
      ) do
    {:noreply, insert_service_events(socket, EventView.from_event(event))}
  end

  def handle_info(
        {:upnp, ref, %Lifecycle{} = lifecycle},
        %{assigns: %{watch_ref: ref}} = socket
      ) do
    {:noreply, insert_service_events(socket, [EventView.from_lifecycle(lifecycle)])}
  end

  def handle_info(:show_scan_help, socket) do
    {:noreply, assign(socket, :show_scan_help?, socket.assigns.status.device_count == 0)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    close_watch(socket.assigns[:watch_subscription])
    :ok
  end

  defp select_device(socket, nil) do
    socket
    |> stop_watch()
    |> assign(
      selected_device: nil,
      selected_service_id: nil,
      service_detail: nil,
      service_loading?: false,
      service_error: nil,
      action_operation: nil
    )
    |> stream(:device_nodes, [], reset: true)
    |> stream(:services, [], reset: true)
    |> stream(:service_actions, [], reset: true)
    |> stream(:state_variables, [], reset: true)
    |> stream(:service_events, [], reset: true)
  end

  defp select_device(socket, device_id) do
    case Explorer.get_device(device_id) do
      {:ok, device} ->
        socket
        |> stop_watch()
        |> assign(
          selected_device: device,
          selected_service_id: nil,
          service_detail: nil,
          service_loading?: false,
          service_error: nil,
          action_operation: nil
        )
        |> stream(:device_nodes, device.nodes, reset: true)
        |> stream(:services, device.services, reset: true)
        |> stream(:service_actions, [], reset: true)
        |> stream(:state_variables, [], reset: true)
        |> stream(:service_events, [], reset: true)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "That device is no longer in the live roster.")
        |> push_patch(to: ~p"/")
    end
  end

  defp insert_service_events(socket, events) do
    Enum.reduce(events, socket, fn event, current ->
      stream_insert(current, :service_events, event, at: 0, limit: 40)
    end)
  end

  defp stop_watch(socket) do
    close_watch(socket.assigns.watch_subscription)

    socket
    |> assign(
      watch_subscription: nil,
      watch_ref: nil,
      watch_loading?: false,
      watch_error: nil
    )
    |> stream(:service_events, [], reset: true)
  end

  defp close_watch(nil), do: :ok
  defp close_watch(subscription), do: Subscription.close(subscription)

  defp selected_device_id(%{assigns: %{selected_device: nil}}), do: nil
  defp selected_device_id(socket), do: socket.assigns.selected_device.id

  defp changes_only(activities), do: Enum.filter(activities, &Activity.matches?(&1, :changes))

  defp prepare_action_form(action) do
    defaults =
      Enum.reduce(action.inputs, %{}, fn
        %{wire_name: name, suggested_value: value}, values when is_binary(name) ->
          Map.put_new(values, name, value)

        _argument, values ->
          values
      end)

    Map.put(action, :form, to_form(defaults, as: :arguments))
  end

  defp find_action(%{assigns: %{service_detail: %{actions: actions}}}, action_name) do
    case Enum.find(actions, &(&1.wire_name == action_name and &1.invokable?)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  defp find_action(_socket, _action_name), do: :error

  defp valid_arguments?(arguments) when is_map(arguments) and not is_struct(arguments) do
    Enum.all?(arguments, fn {name, value} -> is_binary(name) and is_binary(value) end)
  end

  defp valid_arguments?(_arguments), do: false

  defp prepare_confirmation(socket, action, arguments) do
    operation = %{
      phase: :confirming,
      service_id: socket.assigns.selected_service_id,
      action_name: action.wire_name,
      arguments: arguments,
      prepared_at: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:action_operation, operation)
    |> update_action(action.wire_name,
      operation_status: :confirming,
      operation_result: nil,
      operation_error: nil,
      pending_arguments: arguments
    )
  end

  defp start_action(socket, action, arguments) do
    device_id = socket.assigns.selected_device.id
    service_id = socket.assigns.selected_service_id
    action_name = action.wire_name

    operation = %{
      phase: :running,
      service_id: service_id,
      action_name: action_name,
      arguments: arguments
    }

    socket
    |> assign(:action_operation, operation)
    |> update_action(action_name,
      operation_status: :running,
      operation_result: nil,
      operation_error: nil,
      pending_arguments: %{}
    )
    |> start_async({:invoke_action, service_id, action_name}, fn ->
      Explorer.invoke_action(device_id, service_id, action_name, arguments,
        record_activity?: action.policy.confirmation_required?
      )
    end)
  end

  defp confirmation_fresh?(prepared_at) do
    System.monotonic_time(:millisecond) - prepared_at <= @confirmation_ttl_ms
  end

  defp update_action(socket, action_name, attributes) do
    action = Enum.find(socket.assigns.service_detail.actions, &(&1.wire_name == action_name))

    if action do
      stream_insert(socket, :service_actions, Map.merge(action, Map.new(attributes)))
    else
      socket
    end
  end

  defp action_policy_class(%{kind: :query}),
    do: "border-[var(--accent-border)] bg-[var(--accent-soft)] text-[var(--accent)]"

  defp action_policy_class(%{kind: :change}),
    do: "border-[var(--warning-border)] bg-[var(--warning-soft)] text-[var(--warning)]"

  defp action_policy_class(%{kind: kind}) when kind in [:destructive, :disruptive],
    do: "border-[var(--danger-border)] bg-[var(--danger-soft)] text-[var(--danger)]"

  defp action_panel_class(%{kind: :query}),
    do: "border-[var(--accent-border)] bg-[var(--accent-soft)]"

  defp action_panel_class(%{kind: :change}),
    do: "border-[var(--warning-border)] bg-[var(--warning-soft)]"

  defp action_panel_class(%{kind: kind}) when kind in [:destructive, :disruptive],
    do: "border-[var(--danger-border)] bg-[var(--danger-soft)]"

  defp argument_hint(argument) do
    [
      argument.data_type || "string",
      argument.minimum && argument.maximum && "#{argument.minimum}..#{argument.maximum}",
      argument.default_value && "default #{argument.default_value}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp device_subtitle(device) do
    [device.manufacturer, device.model]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> device.host
      value -> value
    end
  end

  defp device_status_label(:online), do: "Online"
  defp device_status_label(:degraded), do: "Degraded"
  defp device_status_label(:describing), do: "Describing"
  defp device_status_label(:discovered), do: "Discovered"

  defp action_signature(action) do
    inputs = Enum.map_join(action.inputs, ", ", & &1.name)
    outputs = Enum.map_join(action.outputs, ", ", & &1.name)

    case {inputs, outputs} do
      {"", ""} -> "No arguments"
      {"", values} -> "returns #{values}"
      {values, ""} -> "accepts #{values}"
      {given, returned} -> "accepts #{given}; returns #{returned}"
    end
  end

  defp variable_constraint(variable) do
    cond do
      variable.allowed_values != [] -> Enum.join(variable.allowed_values, " | ")
      variable.minimum && variable.maximum -> "#{variable.minimum} to #{variable.maximum}"
      variable.default_value -> "default #{variable.default_value}"
      true -> nil
    end
  end

  defp event_meta(event) do
    [
      event.replay? && "replay",
      event.initial? && "initial",
      event.sequence && "SEQ #{event.sequence}",
      event.channel && "channel #{event.channel}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp safe_http_url(nil), do: nil

  defp safe_http_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> url
      _uri -> nil
    end
  end

  defp format_reason(reason) do
    case reason do
      exception when is_exception(exception) -> Exception.message(exception)
      value -> inspect(value, pretty: true, limit: 8, printable_limit: 220)
    end
  end
end
