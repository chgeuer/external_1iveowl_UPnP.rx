Code.require_file("_support.exs", __DIR__)

defmodule UPnP.Samples.Eventing do
  @moduledoc false

  alias UPnP.{DescribedDevice, EventedProperty, Service, Subscription}
  alias UPnP.Eventing.{Event, Lifecycle}
  alias UPnP.Samples.Runtime

  @usage """
  Usage: mix run samples/eventing.exs [options]

  Discover evented services, choose one, and print its GENA state changes until
  Enter is pressed.

    --timeout SECONDS    Requested subscription timeout (default: 1800)
    --discovery SECONDS  SSDP collection window (default: 8)
    --service INDEX      Select a listed service without prompting
    --duration SECONDS   Unsubscribe automatically after this many seconds
    -h, --help           Show this help
  """

  @switches [
    timeout: :integer,
    discovery: :integer,
    service: :integer,
    duration: :integer,
    help: :boolean
  ]

  @spec main([String.t()]) :: :ok
  def main(arguments) do
    case OptionParser.parse(arguments, strict: @switches, aliases: [h: :help]) do
      {options, [], []} ->
        options = Keyword.merge([timeout: 1_800, discovery: 8], options)

        cond do
          options[:help] -> IO.puts(@usage)
          error = validate(options) -> usage_error(error)
          true -> run(options)
        end

      {_options, remaining, invalid} ->
        usage_error("invalid arguments: #{inspect(remaining ++ invalid)}")
    end
  end

  defp run(options) do
    control_point_options = [event_subscription_timeout: options[:timeout] * 1_000]

    case Runtime.start_control_point(control_point_options) do
      {:ok, control_point, _addresses} ->
        try do
          find_and_subscribe(control_point, options)
        after
          Runtime.close_control_point(control_point)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Cannot start discovery: #{Runtime.format_reason(reason)}")
    end
  end

  defp find_and_subscribe(control_point, options) do
    IO.puts("UPnP eventing sample (subscription timeout: #{options[:timeout]}s)")
    IO.puts("Discovering evented services (#{options[:discovery]} s)...")

    case Runtime.discover_described(control_point, options[:discovery] * 1_000) do
      {:ok, described, failures} ->
        candidates = evented_services(described)

        if failures != [] do
          IO.puts("Skipped #{length(failures)} description(s) that could not be read.")
        end

        choose_and_subscribe(candidates, options)

      {:error, reason} ->
        IO.puts(:stderr, "Discovery failed: #{Runtime.format_reason(reason)}")
    end
  end

  defp evented_services(devices) do
    devices
    |> Enum.flat_map(fn described ->
      name = described.description.friendly_name || "(unnamed)"

      described
      |> DescribedDevice.services()
      |> Enum.filter(&match?(%URI{}, &1.description.event_sub_url))
      |> Enum.map(&{name, &1})
    end)
    |> Enum.uniq_by(fn {_name, service} ->
      {
        service.description.service_type,
        URI.to_string(service.description.event_sub_url)
      }
    end)
    |> Enum.sort_by(fn {name, service} ->
      {name, service.description.service_type || ""}
    end)
  end

  defp choose_and_subscribe([], _options) do
    IO.puts("""
    No evented services found. Run on the host network and check VPN, firewall,
    and multicast settings.
    """)
  end

  defp choose_and_subscribe(candidates, options) do
    candidates
    |> Enum.with_index()
    |> Enum.each(fn {{device_name, service}, index} ->
      IO.puts("  [#{index}] #{device_name}  #{service.description.service_type}")
    end)

    with {:ok, index} <- chosen_index(options[:service], length(candidates)),
         {_name, service} <- Enum.at(candidates, index) do
      subscribe(service, options[:duration])
    else
      {:error, reason} -> IO.puts(reason)
    end
  end

  defp chosen_index(index, count) when is_integer(index) do
    if index >= 0 and index < count,
      do: {:ok, index},
      else: {:error, "No valid pick; exiting."}
  end

  defp chosen_index(nil, count) do
    case IO.gets("Pick a service number: ") do
      line when is_binary(line) ->
        case Integer.parse(String.trim(line)) do
          {index, ""} when index >= 0 and index < count -> {:ok, index}
          _result -> {:error, "No valid pick; exiting."}
        end

      _eof ->
        {:error, "No valid pick; exiting."}
    end
  end

  defp subscribe(service, duration) do
    IO.puts(
      "\nSubscribing to #{service.description.service_type} " <>
        "- press Enter to unsubscribe gracefully.\n"
    )

    case Service.subscribe(service) do
      {:ok, subscription, snapshot} ->
        Enum.each(snapshot, fn property ->
          IO.puts("  (replay)  #{property_name(property)} = #{trim(property.value)}")
        end)

        input = Runtime.start_input_reader(self(), :unsubscribe)
        timer = if duration, do: Process.send_after(self(), :unsubscribe, duration * 1_000)

        try do
          event_loop(subscription.ref)
        after
          if timer, do: Process.cancel_timer(timer)
          Runtime.stop_input_reader(input)
          Subscription.close(subscription)
        end

        IO.puts("Unsubscribed.")

      {:error, reason} ->
        IO.puts(:stderr, "Subscription failed: #{Runtime.format_reason(reason)}")
    end
  end

  defp event_loop(subscription_ref) do
    receive do
      {:upnp, ^subscription_ref, %Event{} = event} ->
        Enum.each(event.properties, &print_property(event, &1))
        event_loop(subscription_ref)

      {:upnp, ^subscription_ref, %Lifecycle{} = lifecycle} ->
        print_lifecycle(lifecycle)
        event_loop(subscription_ref)

      :unsubscribe ->
        :ok
    end
  end

  defp print_property(%Event{initial?: true}, property) do
    IO.puts("  (initial) #{property_name(property)} = #{trim(property.value)}")
  end

  defp print_property(%Event{sequence: sequence}, property) do
    IO.puts("  [#{sequence}] #{property_name(property)} = #{trim(property.value)}")
  end

  defp print_lifecycle(lifecycle) do
    details =
      [
        lifecycle.sid && "sid=#{lifecycle.sid}",
        lifecycle.timeout && "timeout=#{inspect(lifecycle.timeout)}",
        lifecycle.expected_sequence && "expected=#{lifecycle.expected_sequence}",
        lifecycle.actual_sequence && "actual=#{lifecycle.actual_sequence}",
        lifecycle.attempt && "attempt=#{lifecycle.attempt}",
        lifecycle.reason && "reason=#{Runtime.format_reason(lifecycle.reason)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("  ")

    suffix = if details == "", do: "", else: "  #{details}"
    IO.puts("  #{lifecycle.kind |> Atom.to_string() |> String.upcase()}#{suffix}")
  end

  defp property_name(%EventedProperty{name: nil}), do: "(unnamed)"
  defp property_name(%EventedProperty{name: name}), do: name

  defp trim(nil), do: ""

  defp trim(value) do
    if String.length(value) <= 120 do
      value
    else
      String.slice(value, 0, 120) <> "…"
    end
  end

  defp validate(options) do
    cond do
      options[:timeout] <= 0 -> "--timeout must be greater than zero"
      options[:discovery] <= 0 -> "--discovery must be greater than zero"
      options[:service] && options[:service] < 0 -> "--service cannot be negative"
      options[:duration] && options[:duration] <= 0 -> "--duration must be greater than zero"
      true -> nil
    end
  end

  defp usage_error(message), do: IO.puts(:stderr, "#{message}\n\n#{@usage}")
end

UPnP.Samples.Eventing.main(System.argv())
