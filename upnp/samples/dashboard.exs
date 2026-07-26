Code.require_file("_support.exs", __DIR__)

defmodule UPnP.Samples.Dashboard.State do
  @moduledoc false

  use GenServer

  alias UPnP.{Announcement, ControlPoint, DescribedDevice, Device, Subscription}
  alias UPnP.IGD
  alias UPnP.IGD.Gateway
  alias UPnP.Roster.Event
  alias UPnP.Samples.Interfaces
  alias UPnP.SSDP.SearchTarget

  @activity_limit 80

  @spec start_link(GenServer.server()) :: GenServer.on_start()
  def start_link(control_point) do
    GenServer.start_link(__MODULE__, control_point, name: __MODULE__)
  end

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec probe() :: :ok | {:error, term()}
  def probe, do: GenServer.call(__MODULE__, :probe, :infinity)

  @spec refresh_gateway() :: :ok
  def refresh_gateway, do: GenServer.call(__MODULE__, :refresh_gateway)

  @impl true
  def init(control_point) do
    with {:ok, roster_subscription, devices} <-
           ControlPoint.subscribe_roster(control_point),
         {:ok, announcement_subscription} <-
           ControlPoint.subscribe_announcements(control_point),
         :ok <-
           ControlPoint.search(
             control_point,
             target: SearchTarget.root_device()
           ) do
      state = %{
        control_point: control_point,
        roster_subscription: roster_subscription,
        announcement_subscription: announcement_subscription,
        pending: %{},
        pending_keys: MapSet.new(),
        described_boots: MapSet.new(),
        descriptions: %{},
        device_descriptions: %{},
        errors: %{},
        activities: [],
        gateway: :loading
      }

      state =
        devices
        |> Enum.reduce(state, &start_description/2)
        |> start_gateway_load()

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      descriptions:
        state.descriptions
        |> Map.values()
        |> Enum.sort_by(&description_sort_key/1),
      pending_descriptions:
        Enum.count(state.pending, fn {_ref, entry} -> entry.kind == :description end),
      description_errors: state.errors,
      activities: state.activities,
      gateway: state.gateway
    }

    {:reply, snapshot, state}
  end

  def handle_call(:probe, _from, state) do
    result =
      ControlPoint.search(
        state.control_point,
        target: SearchTarget.root_device()
      )

    {:reply, result, state}
  end

  def handle_call(:refresh_gateway, _from, state) do
    {:reply, :ok, start_gateway_load(%{state | gateway: :loading})}
  end

  @impl true
  def handle_info(
        {:upnp, ref, %Event{} = event},
        %{roster_subscription: %{ref: ref}} = state
      ) do
    state =
      case event.kind do
        kind when kind in [:appeared, :updated] -> start_description(event.device, state)
        kind when kind in [:left, :expired] -> remove_device(event.device, state)
      end

    {:noreply, state}
  end

  def handle_info(
        {:upnp, ref, %Announcement{} = announcement},
        %{announcement_subscription: %{ref: ref}} = state
      ) do
    activities = [announcement | state.activities] |> Enum.take(@activity_limit)
    {:noreply, %{state | activities: activities}}
  end

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        Process.demonitor(task_ref, [:flush])
        state = %{state | pending: pending}
        {:noreply, finish_task(entry, result, state)}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        state = %{state | pending: pending}
        {:noreply, fail_task(entry, reason, state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {_ref, %{task: task}} ->
      Task.shutdown(task, :brutal_kill)
    end)

    Subscription.close(state.roster_subscription)
    Subscription.close(state.announcement_subscription)
    :ok
  end

  defp start_description(device, state) do
    boot_key = Device.boot_identity(device)

    cond do
      MapSet.member?(state.pending_keys, boot_key) ->
        state

      MapSet.member?(state.described_boots, boot_key) ->
        state

      true ->
        task =
          Task.Supervisor.async_nolink(
            UPnP.TaskSupervisor,
            fn -> ControlPoint.describe(state.control_point, device) end
          )

        entry = %{
          kind: :description,
          task: task,
          boot_key: boot_key,
          device_key: Device.identity(device)
        }

        %{
          state
          | pending: Map.put(state.pending, task.ref, entry),
            pending_keys: MapSet.put(state.pending_keys, boot_key)
        }
    end
  end

  defp start_gateway_load(state) do
    loading? = Enum.any?(state.pending, fn {_ref, entry} -> entry.kind == :gateway end)

    if loading? do
      state
    else
      task =
        Task.Supervisor.async_nolink(
          UPnP.TaskSupervisor,
          fn -> load_gateway(state.control_point) end
        )

      entry = %{kind: :gateway, task: task}
      %{state | pending: Map.put(state.pending, task.ref, entry)}
    end
  end

  defp finish_task(
         %{kind: :description, boot_key: boot_key, device_key: device_key},
         {:ok, %DescribedDevice{} = described},
         state
       ) do
    description_key = description_key(described)

    %{
      state
      | pending_keys: MapSet.delete(state.pending_keys, boot_key),
        described_boots: MapSet.put(state.described_boots, boot_key),
        descriptions: Map.put(state.descriptions, description_key, described),
        device_descriptions: Map.put(state.device_descriptions, device_key, description_key),
        errors: Map.delete(state.errors, boot_key)
    }
  end

  defp finish_task(
         %{kind: :description, boot_key: boot_key},
         {:error, reason},
         state
       ) do
    %{
      state
      | pending_keys: MapSet.delete(state.pending_keys, boot_key),
        errors: Map.put(state.errors, boot_key, reason)
    }
  end

  defp finish_task(%{kind: :gateway}, gateway, state), do: %{state | gateway: gateway}

  defp fail_task(%{kind: :description, boot_key: boot_key}, reason, state) do
    %{
      state
      | pending_keys: MapSet.delete(state.pending_keys, boot_key),
        errors: Map.put(state.errors, boot_key, {:task_exit, reason})
    }
  end

  defp fail_task(%{kind: :gateway}, reason, state),
    do: %{state | gateway: {:error, {:task_exit, reason}}}

  defp remove_device(device, state) do
    device_key = Device.identity(device)
    {description_key, device_descriptions} = Map.pop(state.device_descriptions, device_key)

    descriptions =
      if description_key &&
           description_key not in Map.values(device_descriptions) do
        Map.delete(state.descriptions, description_key)
      else
        state.descriptions
      end

    %{
      state
      | descriptions: descriptions,
        device_descriptions: device_descriptions,
        described_boots: MapSet.delete(state.described_boots, Device.boot_identity(device))
    }
  end

  defp load_gateway(control_point) do
    case IGD.discover_gateway(control_point, mx: 3) do
      {:ok, nil} ->
        :none

      {:ok, gateway} ->
        status = tagged_value(Gateway.status(gateway))
        external_address = tagged_value(Gateway.external_address(gateway))
        mappings = tagged_value(Gateway.list_port_mappings(gateway, max_entries: 256))

        {:ok,
         %{
           friendly_name: gateway.device.description.friendly_name,
           service_type: gateway.wan_service.description.service_type,
           local_address: gateway.local_address && Interfaces.format(gateway.local_address),
           status: status,
           external_address: external_address,
           mappings: mappings
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tagged_value({:ok, value}), do: {:ok, value}
  defp tagged_value({:error, reason}), do: {:error, reason}

  defp description_key(described) do
    {
      described.description.location && URI.to_string(described.description.location),
      described.description.udn || Device.identity(described.device)
    }
  end

  defp description_sort_key(described) do
    {
      described.description.friendly_name || "",
      described.description.location && URI.to_string(described.description.location)
    }
  end
end

defmodule UPnP.Samples.Dashboard.Plug do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias UPnP.IGD.{Protocol, Status}
  alias UPnP.Samples.{DeviceTree, Interfaces, Runtime}
  alias UPnP.Samples.Dashboard.State

  plug(:match)
  plug(:dispatch)

  get "/" do
    snapshot = State.snapshot()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render(snapshot))
  end

  post "/probe" do
    _result = State.probe()
    redirect_home(conn)
  end

  post "/gateway/refresh" do
    :ok = State.refresh_gateway()
    redirect_home(conn)
  end

  get "/health" do
    send_resp(conn, 200, "ok\n")
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  defp redirect_home(conn) do
    conn
    |> put_resp_header("location", "/")
    |> send_resp(303, "")
  end

  defp render(snapshot) do
    device_count = length(snapshot.descriptions)

    [
      """
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="3">
        <title>UPnP dashboard</title>
        <style>
          :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, sans-serif; }
          body { max-width: 1100px; margin: 0 auto; padding: 2rem; background: #101318; color: #edf2f7; }
          header, .toolbar, .card-head { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
          h1 { margin: 0; font-size: 1.6rem; } h2 { margin: 2rem 0 .8rem; font-size: 1.1rem; }
          .muted { color: #9aa6b2; } .badge { padding: .25rem .55rem; border: 1px solid #3b4652; border-radius: 999px; }
          .toolbar { margin: 1.5rem 0; justify-content: flex-start; }
          button { padding: .55rem .8rem; border: 1px solid #556373; border-radius: .35rem; background: #1b222b; color: inherit; cursor: pointer; }
          .card { margin: .75rem 0; border: 1px solid #2d3742; border-radius: .55rem; background: #171c23; overflow: hidden; }
          .card-head { padding: .9rem 1rem; background: #1d242d; }
          .card-body { padding: 1rem; } .name { font-weight: 700; } a { color: #75baff; }
          pre { overflow-x: auto; margin: 0; font: .82rem/1.55 ui-monospace, monospace; color: #c9d7e5; }
          table { width: 100%; border-collapse: collapse; font-size: .9rem; }
          th, td { padding: .5rem; border-bottom: 1px solid #2d3742; text-align: left; }
          .activity { display: grid; grid-template-columns: 8rem 10rem 1fr; gap: .6rem; padding: .35rem 0; border-bottom: 1px solid #242c35; font: .8rem ui-monospace, monospace; }
          .error { color: #ff9b9b; } footer { margin-top: 2rem; color: #788592; font-size: .8rem; }
          @media (max-width: 700px) { body { padding: 1rem; } .activity { grid-template-columns: 1fr; } }
        </style>
      </head>
      <body>
        <header>
          <div><h1>UPnP network dashboard</h1><div class="muted">OTP roster · Bandit/Plug</div></div>
          <span class="badge">#{device_count} device(s)</span>
        </header>
        <div class="toolbar">
          <form method="post" action="/probe"><button type="submit">Search now</button></form>
          <span class="muted">Auto-refreshes every 3 seconds</span>
        </div>
      """,
      render_devices(snapshot),
      render_gateway(snapshot.gateway),
      render_activities(snapshot.activities),
      """
        <footer>Descriptions pending: #{snapshot.pending_descriptions} · description errors: #{map_size(snapshot.description_errors)}</footer>
      </body>
      </html>
      """
    ]
    |> IO.iodata_to_binary()
  end

  defp render_devices(%{descriptions: []}) do
    """
    <div class="card"><div class="card-body">
      Scanning the network. Run this sample on the host if devices do not appear.
    </div></div>
    """
  end

  defp render_devices(snapshot) do
    [
      "<h2>Devices</h2>",
      Enum.map(snapshot.descriptions, fn described ->
        description = described.description
        location = description.location && URI.to_string(description.location)

        [
          ~s(<section class="card"><div class="card-head"><div><div class="name">),
          h(description.friendly_name || "(unnamed device)"),
          ~s(</div><div class="muted">),
          h(
            [description.manufacturer, description.model_name]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" ")
          ),
          ~s(</div></div><a href="),
          h(location || "#"),
          ~s(" target="_blank">description</a></div><div class="card-body"><pre>),
          description |> DeviceTree.render() |> h(),
          "</pre></div></section>"
        ]
      end)
    ]
  end

  defp render_gateway(:loading) do
    """
    <h2>Internet gateway</h2>
    <div class="card"><div class="card-body">Searching for an IGD gateway…</div></div>
    """
  end

  defp render_gateway(:none) do
    """
    <h2>Internet gateway</h2>
    <div class="card"><div class="card-body">
      No IGD gateway answered.
      <form method="post" action="/gateway/refresh"><button type="submit">Search again</button></form>
    </div></div>
    """
  end

  defp render_gateway({:error, reason}) do
    [
      "<h2>Internet gateway</h2><div class=\"card\"><div class=\"card-body error\">",
      "Gateway query failed: ",
      reason |> Runtime.format_reason() |> h(),
      ~s(<form method="post" action="/gateway/refresh"><button type="submit">Retry</button></form>),
      "</div></div>"
    ]
  end

  defp render_gateway({:ok, gateway}) do
    [
      """
      <h2>Internet gateway</h2>
      <section class="card">
        <div class="card-head"><div><div class="name">
      """,
      h(gateway.friendly_name || "(unnamed gateway)"),
      ~s(</div><div class="muted">),
      h(gateway.service_type || "(unknown service)"),
      """
      </div></div>
      <form method="post" action="/gateway/refresh"><button type="submit">Refresh</button></form>
      </div><div class="card-body">
      """,
      gateway_summary(gateway),
      gateway_mappings(gateway.mappings),
      "</div></section>"
    ]
  end

  defp gateway_summary(gateway) do
    status =
      case gateway.status do
        {:ok, %Status{} = value} ->
          "#{value.status || "unknown"} · uptime #{Runtime.format_seconds(value.uptime)} · " <>
            "last error #{value.last_error || "unknown"}"

        {:error, reason} ->
          "status query failed: #{Runtime.format_reason(reason)}"
      end

    external =
      case gateway.external_address do
        {:ok, address} -> Interfaces.format(address)
        {:error, reason} -> "query failed: #{Runtime.format_reason(reason)}"
      end

    [
      "<p><strong>WAN:</strong> ",
      h(status),
      "<br><strong>External address:</strong> ",
      h(external),
      "<br><strong>Local address:</strong> ",
      h(gateway.local_address || "unknown"),
      "</p>"
    ]
  end

  defp gateway_mappings({:error, reason}) do
    [
      "<p class=\"error\">Mapping enumeration failed: ",
      reason |> Runtime.format_reason() |> h(),
      "</p>"
    ]
  end

  defp gateway_mappings({:ok, []}), do: "<p class=\"muted\">No port mappings.</p>"

  defp gateway_mappings({:ok, mappings}) do
    [
      """
      <table><thead><tr><th>Protocol</th><th>External</th><th>Internal</th><th>Client</th><th>Description</th><th>Lease</th></tr></thead><tbody>
      """,
      Enum.map(mappings, fn mapping ->
        [
          "<tr><td>",
          Protocol.to_wire(mapping.protocol),
          "</td><td>",
          Integer.to_string(mapping.external_port),
          "</td><td>",
          Integer.to_string(mapping.internal_port),
          "</td><td>",
          h(mapping.internal_client),
          "</td><td>",
          h(mapping.description),
          "</td><td>",
          if(mapping.lease_duration == 0,
            do: "infinite",
            else: "#{mapping.lease_duration}s"
          ),
          "</td></tr>"
        ]
      end),
      "</tbody></table>"
    ]
  end

  defp render_activities([]) do
    """
    <h2>SSDP activity</h2>
    <div class="card"><div class="card-body muted">Waiting for announcements and search responses…</div></div>
    """
  end

  defp render_activities(activities) do
    [
      "<h2>SSDP activity</h2><div class=\"card\"><div class=\"card-body\">",
      Enum.map(activities, fn announcement ->
        device = announcement.device

        [
          "<div class=\"activity\"><span>",
          announcement.received_at |> Calendar.strftime("%H:%M:%S") |> h(),
          "</span><strong>",
          announcement.kind |> Atom.to_string() |> h(),
          "</strong><span>",
          h(device.usn || URI.to_string(device.location)),
          "</span></div>"
        ]
      end),
      "</div></div>"
    ]
  end

  defp h(nil), do: ""
  defp h(value) when is_binary(value), do: Plug.HTML.html_escape_to_iodata(value)
end

defmodule UPnP.Samples.Dashboard do
  @moduledoc false

  alias UPnP.Samples.{Interfaces, Runtime}
  alias UPnP.Samples.Dashboard.State

  @usage """
  Usage: mix run samples/dashboard.exs [options]

  Start a server-rendered UPnP dashboard backed by an OTP roster.

    --port PORT         HTTP port (default: 4000; use 0 for an ephemeral port)
    --duration SECONDS  Stop automatically after this many seconds
    -h, --help          Show this help
  """

  @spec main([String.t()]) :: :ok
  def main(arguments) do
    case OptionParser.parse(arguments,
           strict: [port: :integer, duration: :integer, help: :boolean],
           aliases: [h: :help]
         ) do
      {options, [], []} ->
        options = Keyword.put_new(options, :port, 4_000)

        cond do
          options[:help] ->
            IO.puts(@usage)

          options[:port] not in 0..65_535 ->
            usage_error("--port must be between 0 and 65535")

          options[:duration] && options[:duration] <= 0 ->
            usage_error("--duration must be greater than zero")

          true ->
            run(options)
        end

      {_options, remaining, invalid} ->
        usage_error("invalid arguments: #{inspect(remaining ++ invalid)}")
    end
  end

  defp run(options) do
    case Runtime.start_control_point() do
      {:ok, control_point, addresses} ->
        try do
          start_dashboard(control_point, addresses, options)
        after
          Runtime.close_control_point(control_point)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Cannot start discovery: #{Runtime.format_reason(reason)}")
    end
  end

  defp start_dashboard(control_point, addresses, options) do
    case State.start_link(control_point) do
      {:ok, state} ->
        try do
          start_http(addresses, options)
        after
          if Process.alive?(state), do: GenServer.stop(state)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Dashboard state failed to start: #{Runtime.format_reason(reason)}")
    end
  end

  defp start_http(addresses, options) do
    case Bandit.start_link(
           plug: UPnP.Samples.Dashboard.Plug,
           ip: :any,
           port: options[:port],
           startup_log: false,
           http_2_options: [enabled: false]
         ) do
      {:ok, bandit} ->
        try do
          case ThousandIsland.listener_info(bandit) do
            {:ok, {_bind_address, port}} ->
              wait_for_stop(addresses, port, options)

            :error ->
              IO.puts(:stderr, "Dashboard listener information is unavailable.")
          end
        after
          if Process.alive?(bandit), do: Supervisor.stop(bandit)
        end

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Dashboard HTTP server failed to start: #{Runtime.format_reason(reason)}"
        )
    end
  end

  defp wait_for_stop(addresses, port, options) do
    print_urls(addresses, port)

    input =
      if System.get_env("UPNP_SAMPLE_NO_INPUT") == "1" do
        nil
      else
        Runtime.start_input_reader(self(), :stop_dashboard)
      end

    timer =
      if duration = options[:duration],
        do: Process.send_after(self(), :stop_dashboard, duration * 1_000)

    try do
      receive do
        :stop_dashboard -> :ok
      end
    after
      if timer, do: Process.cancel_timer(timer)
      Runtime.stop_input_reader(input)
    end
  end

  defp print_urls(addresses, port) do
    IO.puts("UPnP dashboard is running. Press Enter to stop.")
    IO.puts("  http://127.0.0.1:#{port}")

    Enum.each(addresses, fn address ->
      IO.puts("  http://#{Interfaces.format(address)}:#{port}")
    end)

    IO.puts("")
  end

  defp usage_error(message), do: IO.puts(:stderr, "#{message}\n\n#{@usage}")
end

UPnP.Samples.Dashboard.main(System.argv())
