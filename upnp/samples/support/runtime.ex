defmodule UPnP.Samples.Runtime do
  @moduledoc false

  alias UPnP.{ControlPoint, DescribedDevice, Device, Subscription}
  alias UPnP.Roster.Event
  alias UPnP.Samples.Interfaces
  alias UPnP.SSDP.SearchTarget

  @spec start_control_point(keyword()) ::
          {:ok, pid(), [:inet.ip4_address()]} | {:error, term()}
  def start_control_point(options \\ []) do
    with {:ok, addresses} <- Interfaces.ipv4_addresses(),
         false <- addresses == [],
         {:ok, control_point} <-
           options
           |> Keyword.put(:interfaces, addresses)
           |> UPnP.start_control_point() do
      {:ok, control_point, addresses}
    else
      true -> {:error, :no_usable_ipv4_interfaces}
      {:error, _reason} = error -> error
    end
  end

  @spec close_control_point(GenServer.server()) :: :ok
  def close_control_point(control_point), do: ControlPoint.close(control_point)

  @spec discover_described(GenServer.server(), non_neg_integer()) ::
          {:ok, [DescribedDevice.t()], [{Device.t() | nil, term()}]} | {:error, term()}
  def discover_described(control_point, wait_ms)
      when is_integer(wait_ms) and wait_ms >= 0 do
    with {:ok, subscription, current} <- ControlPoint.subscribe_roster(control_point) do
      try do
        with :ok <-
               ControlPoint.search(
                 control_point,
                 target: SearchTarget.root_device()
               ) do
          Process.sleep(wait_ms)

          devices =
            subscription.ref
            |> drain_roster(Map.new(current, &{Device.identity(&1), &1}))
            |> Map.values()
            |> Enum.uniq_by(&{URI.to_string(&1.location), &1.boot_id})

          describe_devices(control_point, devices)
        end
      after
        Subscription.close(subscription)
      end
    end
  end

  @spec start_input_reader(pid(), term()) :: pid()
  def start_input_reader(receiver, message) when is_pid(receiver) do
    spawn(fn ->
      case IO.gets("") do
        line when is_binary(line) -> send(receiver, message)
        _eof -> send(receiver, message)
      end
    end)
  end

  @spec stop_input_reader(pid() | nil) :: :ok
  def stop_input_reader(nil), do: :ok

  def stop_input_reader(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  @spec format_addresses([:inet.ip_address()]) :: String.t()
  def format_addresses(addresses), do: Enum.map_join(addresses, ", ", &Interfaces.format/1)

  @spec format_reason(term()) :: String.t()
  def format_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  def format_reason(reason), do: inspect(reason, pretty: true)

  @spec format_seconds(non_neg_integer()) :: String.t()
  def format_seconds(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    remaining = rem(seconds, 60)

    Enum.map_join(
      [hours, minutes, remaining],
      ":",
      &String.pad_leading(Integer.to_string(&1), 2, "0")
    )
  end

  defp drain_roster(ref, devices) do
    receive do
      {:upnp, ^ref, %Event{kind: kind, device: device}}
      when kind in [:appeared, :updated] ->
        drain_roster(ref, Map.put(devices, Device.identity(device), device))

      {:upnp, ^ref, %Event{kind: kind, device: device}}
      when kind in [:left, :expired] ->
        drain_roster(ref, Map.delete(devices, Device.identity(device)))
    after
      0 -> devices
    end
  end

  defp describe_devices(control_point, devices) do
    devices
    |> Task.async_stream(
      &{&1, ControlPoint.describe(control_point, &1)},
      max_concurrency: 8,
      ordered: false,
      timeout: 35_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {_device, {:ok, result}}}, {described, failures} ->
        {[result | described], failures}

      {:ok, {device, {:error, reason}}}, {described, failures} ->
        {described, [{device, reason} | failures]}

      {:exit, reason}, {described, failures} ->
        {described, [{nil, reason} | failures]}
    end)
    |> then(fn {described, failures} ->
      described =
        described
        |> Enum.uniq_by(&description_key/1)
        |> Enum.sort_by(&description_sort_key/1)

      {:ok, described, Enum.reverse(failures)}
    end)
  end

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
