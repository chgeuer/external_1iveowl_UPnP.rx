Code.require_file("_support.exs", __DIR__)

defmodule UPnP.Samples.Browser do
  @moduledoc false

  alias UPnP.{ControlPoint, DescribedDevice, Device, Subscription}
  alias UPnP.Roster.Event
  alias UPnP.Samples.{DeviceTree, Runtime}
  alias UPnP.SSDP.SearchTarget

  @no_devices_delay 15_000
  @first_rediscovery_delay 5_000
  @rediscovery_interval 30_000

  @usage """
  Usage: mix run samples/browser.exs [--duration SECONDS]

  Discover and describe UPnP root devices until Enter is pressed.

    --duration SECONDS  Stop automatically after this many seconds
    -h, --help          Show this help
  """

  @spec main([String.t()]) :: :ok
  def main(arguments) do
    case OptionParser.parse(arguments,
           strict: [duration: :integer, help: :boolean],
           aliases: [h: :help]
         ) do
      {options, [], []} ->
        cond do
          options[:help] ->
            IO.puts(@usage)

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
          browse(control_point, addresses, options)
        after
          Runtime.close_control_point(control_point)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Cannot start the browser: #{Runtime.format_reason(reason)}")
    end
  end

  defp browse(control_point, addresses, options) do
    IO.puts("UPnP network browser")
    IO.puts("Browsing from: #{Runtime.format_addresses(addresses)}")
    IO.puts("Discovering (press Enter to stop)...\n")

    case ControlPoint.subscribe_roster(control_point) do
      {:ok, subscription, devices} ->
        case ControlPoint.search(control_point, target: SearchTarget.root_device()) do
          :ok ->
            input =
              if System.get_env("UPNP_BROWSER_NO_INPUT") == "1" do
                nil
              else
                Runtime.start_input_reader(self(), :stop)
              end

            stop_timer =
              if duration = options[:duration] do
                Process.send_after(self(), :stop, duration * 1_000)
              end

            state = %{
              control_point: control_point,
              subscription: subscription,
              pending: %{},
              pending_keys: MapSet.new(),
              described_boots: MapSet.new(),
              descriptions: %{},
              errors: %{},
              no_devices_timer: Process.send_after(self(), :no_devices, @no_devices_delay),
              rediscovery_timer:
                Process.send_after(
                  self(),
                  :scheduled_rediscovery,
                  @first_rediscovery_delay
                ),
              stop_timer: stop_timer,
              input: input
            }

            final_state = Enum.reduce(devices, state, &start_description/2) |> loop()
            cleanup(final_state)
            IO.puts("#{map_size(final_state.descriptions)} device(s) found.")

          {:error, reason} ->
            Subscription.close(subscription)
            IO.puts(:stderr, "Discovery failed: #{Runtime.format_reason(reason)}")
        end

      {:error, reason} ->
        IO.puts(:stderr, "Discovery failed: #{Runtime.format_reason(reason)}")
    end
  end

  defp loop(state) do
    receive do
      {:upnp, ref, %Event{} = event} when ref == state.subscription.ref ->
        state =
          if event.kind in [:appeared, :updated] do
            start_description(event.device, state)
          else
            state
          end

        loop(state)

      {task_ref, result} when is_reference(task_ref) ->
        loop(finish_description_task(state, task_ref, result))

      {:DOWN, task_ref, :process, _pid, reason} ->
        loop(finish_failed_task(state, task_ref, reason))

      :no_devices ->
        if map_size(state.descriptions) == 0 do
          IO.puts("""
          Nothing answered in 15 seconds. Things to check:
            - Run this sample on the host; multicast usually does not work in
              Docker, WSL, or a devcontainer.
            - Disconnect a VPN that cannot reach the LAN.
            - Check for AP isolation or IGMP snooping on the network.
          Still listening - devices announce themselves periodically...
          """)
        end

        loop(%{state | no_devices_timer: nil})

      :scheduled_rediscovery ->
        case ControlPoint.search(state.control_point, target: SearchTarget.root_device()) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "Rediscovery failed: #{Runtime.format_reason(reason)}")
        end

        timer = Process.send_after(self(), :scheduled_rediscovery, @rediscovery_interval)
        loop(%{state | rediscovery_timer: timer})

      :stop ->
        state
    end
  end

  defp start_description(device, state) do
    key = Device.boot_identity(device)

    cond do
      MapSet.member?(state.pending_keys, key) ->
        state

      MapSet.member?(state.described_boots, key) ->
        state

      true ->
        task =
          Task.Supervisor.async_nolink(
            UPnP.TaskSupervisor,
            fn -> ControlPoint.describe(state.control_point, device) end
          )

        %{
          state
          | pending: Map.put(state.pending, task.ref, %{task: task, key: key}),
            pending_keys: MapSet.put(state.pending_keys, key)
        }
    end
  end

  defp finish_description_task(state, task_ref, result) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        state

      {%{key: key}, pending} ->
        Process.demonitor(task_ref, [:flush])

        state = %{
          state
          | pending: pending,
            pending_keys: MapSet.delete(state.pending_keys, key)
        }

        case result do
          {:ok, %DescribedDevice{} = described} ->
            description_key = description_key(described)

            unless Map.has_key?(state.descriptions, description_key) do
              IO.write(DeviceTree.render(described.description))
            end

            %{
              state
              | descriptions: Map.put(state.descriptions, description_key, described),
                described_boots: MapSet.put(state.described_boots, key),
                errors: Map.delete(state.errors, key)
            }

          {:error, reason} ->
            %{state | errors: Map.put(state.errors, key, reason)}
        end
    end
  end

  defp finish_failed_task(state, task_ref, reason) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        state

      {%{key: key}, pending} ->
        %{
          state
          | pending: pending,
            pending_keys: MapSet.delete(state.pending_keys, key),
            errors: Map.put(state.errors, key, {:task_exit, reason})
        }
    end
  end

  defp cleanup(state) do
    Enum.each(
      [state.no_devices_timer, state.rediscovery_timer, state.stop_timer],
      fn timer -> if timer, do: Process.cancel_timer(timer) end
    )

    Enum.each(state.pending, fn {_ref, %{task: task}} -> Task.shutdown(task, :brutal_kill) end)
    Runtime.stop_input_reader(state.input)
    Subscription.close(state.subscription)
  end

  defp description_key(described) do
    {
      described.description.location && URI.to_string(described.description.location),
      described.description.udn || Device.identity(described.device)
    }
  end

  defp usage_error(message) do
    IO.puts(:stderr, "#{message}\n\n#{@usage}")
  end
end

UPnP.Samples.Browser.main(System.argv())
