Code.require_file("_support.exs", __DIR__)

defmodule UPnP.Samples.PortMapper do
  @moduledoc false

  alias UPnP.IGD
  alias UPnP.IGD.{Gateway, Lease, LeaseEvent, Protocol}
  alias UPnP.Samples.{Interfaces, Runtime}
  alias UPnP.Subscription

  @usage """
  Usage: mix run samples/port_mapper.exs [options]

  Discover an IGD gateway, display its WAN state and port mappings, and
  optionally hold an auto-renewing mapping until Enter is pressed.

    --map                 Create and hold a mapping
    --external-port PORT  External port (default: 18080)
    --internal-port PORT  Internal port (default: 18080)
    --protocol TCP|UDP    Mapping protocol (default: TCP)
    --lease-minutes N     Requested lease (default: 15)
    --description TEXT    Mapping description (default: UPnP Elixir sample)
    --duration SECONDS    Release automatically instead of waiting indefinitely
    -h, --help            Show this help
  """

  @switches [
    map: :boolean,
    external_port: :integer,
    internal_port: :integer,
    protocol: :string,
    lease_minutes: :integer,
    description: :string,
    duration: :integer,
    help: :boolean
  ]

  @spec main([String.t()]) :: :ok
  def main(arguments) do
    case OptionParser.parse(arguments, strict: @switches, aliases: [h: :help]) do
      {options, [], []} ->
        options =
          Keyword.merge(
            [
              external_port: 18_080,
              internal_port: 18_080,
              protocol: "TCP",
              lease_minutes: 15,
              description: "UPnP Elixir sample"
            ],
            options
          )

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
    IO.puts("UPnP port mapper")
    IO.puts("Searching for an internet gateway (up to 10 s)...")

    case Runtime.start_control_point() do
      {:ok, control_point, addresses} ->
        try do
          case IGD.discover_gateway(control_point, mx: 5) do
            {:ok, nil} ->
              no_gateway(addresses)

            {:ok, gateway} ->
              show_gateway(gateway)

              if options[:map] do
                hold_mapping(gateway, options)
              end

            {:error, reason} ->
              IO.puts(:stderr, "Gateway discovery failed: #{Runtime.format_reason(reason)}")
          end
        after
          Runtime.close_control_point(control_point)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Cannot start discovery: #{Runtime.format_reason(reason)}")
    end
  end

  defp show_gateway(gateway) do
    description = gateway.device.description
    IO.puts("Gateway:     #{description.friendly_name || "(unnamed)"}")
    IO.puts("Service:     #{gateway.wan_service.description.service_type || "(unknown)"}")
    IO.puts("Local IP:    #{format_local_address(gateway.local_address)}")

    case Gateway.status(gateway) do
      {:ok, status} ->
        IO.puts(
          "WAN:         #{status.status || "(unknown)"} " <>
            "(uptime #{Runtime.format_seconds(status.uptime)}, " <>
            "last error #{status.last_error || "(unknown)"})"
        )

      {:error, reason} ->
        IO.puts("WAN:         query failed: #{Runtime.format_reason(reason)}")
    end

    case Gateway.external_address(gateway) do
      {:ok, address} ->
        IO.puts("External IP: #{Interfaces.format(address)}")

      {:error, reason} ->
        IO.puts("External IP: query failed: #{Runtime.format_reason(reason)}")
    end

    IO.puts("\nCurrent port mappings:")

    case Gateway.list_port_mappings(gateway) do
      {:ok, []} ->
        IO.puts("  (none)")

      {:ok, mappings} ->
        Enum.each(mappings, &print_mapping/1)

      {:error, reason} ->
        IO.puts("  enumeration failed: #{Runtime.format_reason(reason)}")
    end
  end

  defp print_mapping(mapping) do
    protocol = mapping.protocol |> Protocol.to_wire() |> String.pad_trailing(4)
    external = mapping.external_port |> Integer.to_string() |> String.pad_leading(5)
    lease = if mapping.lease_duration == 0, do: "infinite", else: "#{mapping.lease_duration}s"

    IO.puts(
      "  #{protocol} #{external} -> #{mapping.internal_client}:#{mapping.internal_port}" <>
        "  lease #{lease}  #{inspect(mapping.description)}"
    )
  end

  defp hold_mapping(gateway, options) do
    {:ok, protocol} = Protocol.parse(options[:protocol])
    external_port = options[:external_port]

    case Gateway.get_port_mapping(gateway, external_port, protocol) do
      {:ok, nil} ->
        create_mapping(gateway, protocol, options)

      {:ok, mapping} ->
        IO.puts(
          "\nExternal port #{external_port} is already mapped to " <>
            "#{mapping.internal_client} (#{inspect(mapping.description)})."
        )

      {:error, reason} ->
        IO.puts(
          :stderr,
          "\nCould not inspect port #{external_port}: #{Runtime.format_reason(reason)}"
        )
    end
  end

  defp create_mapping(gateway, protocol, options) do
    lease_seconds = options[:lease_minutes] * 60

    IO.puts(
      "\nMapping #{Protocol.to_wire(protocol)} #{options[:external_port]} -> " <>
        "#{options[:internal_port]} for #{options[:lease_minutes]} minutes (auto-renewing)..."
    )

    case Gateway.add_port_mapping(
           gateway,
           options[:external_port],
           options[:internal_port],
           protocol,
           description: options[:description],
           lease_duration: lease_seconds,
           owner: self()
         ) do
      {:ok, lease} ->
        keep_lease(lease, options[:duration])

      {:error, reason} ->
        print_mapping_error(reason, gateway)
    end
  end

  defp keep_lease(lease, duration) do
    case Lease.subscribe(lease) do
      {:ok, subscription} ->
        input = Runtime.start_input_reader(self(), :release_mapping)
        timer = if duration, do: Process.send_after(self(), :release_mapping, duration * 1_000)

        IO.puts("Mapped external port #{lease.mapping.external_port}. Press Enter to release.")

        try do
          lease_loop(subscription.ref)
        after
          if timer, do: Process.cancel_timer(timer)
          Runtime.stop_input_reader(input)
          Subscription.close(subscription)

          case Lease.close(lease) do
            :ok ->
              IO.puts("Mapping released.")

            {:error, reason} ->
              IO.puts(:stderr, "Mapping cleanup failed: #{Runtime.format_reason(reason)}")
          end
        end

      {:error, reason} ->
        _result = Lease.close(lease)
        IO.puts(:stderr, "Could not watch the lease: #{Runtime.format_reason(reason)}")
    end
  end

  defp lease_loop(subscription_ref) do
    receive do
      {:upnp, ^subscription_ref, %LeaseEvent{} = event} ->
        suffix = if event.reason, do: ": #{Runtime.format_reason(event.reason)}", else: ""
        IO.puts("  [lease] #{event.kind}#{suffix}")
        lease_loop(subscription_ref)

      :release_mapping ->
        :ok
    end
  end

  defp no_gateway(addresses) do
    IO.puts(:stderr, "No internet gateway answered.")
    IO.puts(:stderr, "Searched from: #{Runtime.format_addresses(addresses)}")

    IO.puts(:stderr, """

    Things to check:
      - Enable UPnP/IGD in the router's LAN or NAT settings.
      - Disconnect a VPN that cannot reach the LAN.
      - Run this sample on the host rather than in Docker, WSL, or a devcontainer.
      - Run samples/browser.exs to see whether any UPnP device answers.
    """)
  end

  defp print_mapping_error(
         {:upnp_error, %UPnP.UpnpError{code: 606, description: description}},
         gateway
       ) do
    local_address = format_local_address(gateway.local_address)

    IO.puts(:stderr, """
    The gateway refused the mapping: UPnP error 606 (#{description || "Action not authorized"}).

    UniFi Secure Mode only permits a client to map its own address on a network
    selected in the UPnP settings. This request used #{local_address}. Confirm
    that address belongs to the selected UniFi network; temporarily disabling
    Secure Mode is a useful diagnostic, but is not required for normal use.
    """)
  end

  defp print_mapping_error(reason, _gateway) do
    IO.puts(:stderr, "Could not create the mapping: #{Runtime.format_reason(reason)}")
  end

  defp format_local_address(nil), do: "(unavailable)"
  defp format_local_address(address), do: Interfaces.format(address)

  defp validate(options) do
    cond do
      options[:external_port] not in 1..65_535 ->
        "--external-port must be between 1 and 65535"

      options[:internal_port] not in 1..65_535 ->
        "--internal-port must be between 1 and 65535"

      options[:lease_minutes] <= 0 ->
        "--lease-minutes must be greater than zero"

      options[:duration] && options[:duration] <= 0 ->
        "--duration must be greater than zero"

      not match?({:ok, _protocol}, Protocol.parse(options[:protocol])) ->
        "--protocol must be TCP or UDP"

      true ->
        nil
    end
  end

  defp usage_error(message), do: IO.puts(:stderr, "#{message}\n\n#{@usage}")
end

UPnP.Samples.PortMapper.main(System.argv())
