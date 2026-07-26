defmodule UPnP.IGD.Gateway do
  @moduledoc """
  Typed control over an IGD WANIPConnection or WANPPPConnection service.
  """

  alias UPnP.{
    ActionResult,
    ControlPoint,
    DescribedDevice,
    Network,
    Service
  }

  alias UPnP.IGD.{Lease, Mapping, Protocol, Status}

  @service_priority [
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:2",
    "urn:schemas-upnp-org:service:WANPPPConnection:1"
  ]

  @wan_ip_connection_2 "urn:schemas-upnp-org:service:WANIPConnection:2"

  @enforce_keys [:device, :wan_service, :options]
  defstruct [:device, :wan_service, :local_address, :options]

  @type t :: %__MODULE__{
          device: DescribedDevice.t(),
          wan_service: Service.t(),
          local_address: :inet.ip4_address() | nil,
          options: UPnP.Options.t()
        }

  @doc false
  @spec new(DescribedDevice.t()) :: {:ok, t()} | {:error, :wan_service_not_found}
  def new(%DescribedDevice{} = device) do
    with {:ok, service} <- resolve_wan_service(device) do
      options = ControlPoint.options(device.control_point)

      {:ok,
       %__MODULE__{
         device: device,
         wan_service: service,
         local_address: routed_local_address(service, options.network_adapter),
         options: options
       }}
    end
  end

  @doc "Returns the gateway's external IP address."
  @spec external_address(t(), keyword()) ::
          {:ok, :inet.ip_address()} | {:error, term()}
  def external_address(%__MODULE__{} = gateway, options \\ []) do
    with {:ok, result} <-
           Service.invoke(gateway.wan_service, "GetExternalIPAddress", [], options),
         value when is_binary(value) <- ActionResult.get(result, "NewExternalIPAddress"),
         {:ok, address} <- parse_address(value) do
      {:ok, address}
    else
      nil -> {:error, {:invalid_response, :missing_external_address}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the WAN connection status, last error, and uptime in seconds."
  @spec status(t(), keyword()) :: {:ok, Status.t()} | {:error, term()}
  def status(%__MODULE__{} = gateway, options \\ []) do
    with {:ok, result} <- Service.invoke(gateway.wan_service, "GetStatusInfo", [], options) do
      {:ok,
       %Status{
         status: ActionResult.get(result, "NewConnectionStatus"),
         last_error: ActionResult.get(result, "NewLastConnectionError"),
         uptime: non_negative_integer(ActionResult.get(result, "NewUptime"), 0)
       }}
    end
  end

  @doc """
  Adds a mapping and returns its supervised auto-renewing lease.

  `lease_duration` is in seconds. Zero requests an indefinite mapping and
  deliberately disables both automatic renewal and expiry after abrupt owner
  loss.
  """
  @spec add_port_mapping(
          t(),
          :inet.port_number(),
          :inet.port_number(),
          Protocol.t(),
          keyword()
        ) :: {:ok, Lease.t()} | {:error, term()}
  def add_port_mapping(
        %__MODULE__{} = gateway,
        external_port,
        internal_port,
        protocol,
        options \\ []
      ) do
    add(gateway, external_port, internal_port, protocol, options, false)
  end

  @doc """
  Uses IGD:2 `AddAnyPortMapping` and returns the mapping with its granted port.
  """
  @spec add_any_port_mapping(
          t(),
          :inet.port_number(),
          :inet.port_number(),
          Protocol.t(),
          keyword()
        ) :: {:ok, Lease.t()} | {:error, term()}
  def add_any_port_mapping(
        %__MODULE__{} = gateway,
        external_port,
        internal_port,
        protocol,
        options \\ []
      ) do
    if same_service_type?(gateway.wan_service, @wan_ip_connection_2) do
      add(gateway, external_port, internal_port, protocol, options, true)
    else
      {:error, {:unsupported_action, :add_any_port_mapping}}
    end
  end

  @doc "Removes a port mapping."
  @spec delete_port_mapping(t(), :inet.port_number(), Protocol.t(), keyword()) ::
          :ok | {:error, term()}
  def delete_port_mapping(gateway, external_port, protocol, options \\ [])

  def delete_port_mapping(%__MODULE__{} = gateway, external_port, protocol, options)
      when external_port in 0..65_535 and protocol in [:tcp, :udp] do
    arguments = [
      {"NewRemoteHost", ""},
      {"NewExternalPort", Integer.to_string(external_port)},
      {"NewProtocol", Protocol.to_wire(protocol)}
    ]

    case Service.invoke(gateway.wan_service, "DeletePortMapping", arguments, options) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def delete_port_mapping(%__MODULE__{}, _external_port, _protocol, _options),
    do: {:error, :invalid_mapping}

  @doc "Returns one mapping, or `nil` for UPnP error 714."
  @spec get_port_mapping(t(), :inet.port_number(), Protocol.t(), keyword()) ::
          {:ok, Mapping.t() | nil} | {:error, term()}
  def get_port_mapping(gateway, external_port, protocol, options \\ [])

  def get_port_mapping(%__MODULE__{} = gateway, external_port, protocol, options)
      when external_port in 0..65_535 and protocol in [:tcp, :udp] do
    remote_host = Keyword.get(options, :remote_host, "")

    arguments = [
      {"NewRemoteHost", remote_host},
      {"NewExternalPort", Integer.to_string(external_port)},
      {"NewProtocol", Protocol.to_wire(protocol)}
    ]

    case Service.invoke(
           gateway.wan_service,
           "GetSpecificPortMappingEntry",
           arguments,
           action_options(options)
         ) do
      {:ok, result} ->
        mapping_from_specific(result, remote_host, external_port, protocol)

      {:error, {:upnp_error, %UPnP.UpnpError{code: 714}}} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  def get_port_mapping(%__MODULE__{}, _external_port, _protocol, _options),
    do: {:error, :invalid_mapping}

  @doc """
  Enumerates mappings until the gateway reports array exhaustion.

  `max_entries` defaults to 65,536 and prevents a broken gateway from answering
  every possible index forever.
  """
  @spec list_port_mappings(t(), keyword()) :: {:ok, [Mapping.t()]} | {:error, term()}
  def list_port_mappings(%__MODULE__{} = gateway, options \\ []) do
    max_entries = Keyword.get(options, :max_entries, 65_536)

    if is_integer(max_entries) and max_entries in 0..65_536 do
      enumerate(gateway, options, 0, max_entries, [])
    else
      {:error, :invalid_max_entries}
    end
  end

  @doc false
  @spec renew(t(), Mapping.t()) :: :ok | {:error, term()}
  def renew(%__MODULE__{} = gateway, %Mapping{} = mapping) do
    renew(gateway, mapping, [])
  end

  @doc false
  @spec renew(t(), Mapping.t(), keyword()) :: :ok | {:error, term()}
  def renew(%__MODULE__{} = gateway, %Mapping{} = mapping, options) do
    case Service.invoke(
           gateway.wan_service,
           "AddPortMapping",
           add_arguments(mapping),
           options
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp resolve_wan_service(device) do
    Enum.reduce_while(@service_priority, {:error, :wan_service_not_found}, fn service_type,
                                                                              _result ->
      case DescribedDevice.service(device, service_type) do
        {:ok, service} -> {:halt, {:ok, service}}
        {:error, _reason} -> {:cont, {:error, :wan_service_not_found}}
      end
    end)
  end

  defp add(gateway, external_port, internal_port, protocol, options, use_any?) do
    with :ok <- validate_add(external_port, internal_port, protocol, options, use_any?),
         {:ok, internal_client} <- internal_client(gateway, options),
         mapping <-
           %Mapping{
             remote_host: Keyword.get(options, :remote_host, ""),
             external_port: external_port,
             internal_port: internal_port,
             protocol: protocol,
             internal_client: internal_client,
             enabled: Keyword.get(options, :enabled, true),
             description: Keyword.get(options, :description, ""),
             lease_duration: Keyword.get(options, :lease_duration, 3_600)
           },
         action_options = action_options(options),
         {:ok, mapping} <- invoke_add(gateway, mapping, use_any?, action_options) do
      start_lease(
        gateway,
        mapping,
        Keyword.get(options, :owner, self()),
        action_options
      )
    end
  end

  defp validate_add(external_port, internal_port, protocol, options, use_any?) do
    lease_duration = Keyword.get(options, :lease_duration, 3_600)
    description = Keyword.get(options, :description, "")
    remote_host = Keyword.get(options, :remote_host, "")
    enabled = Keyword.get(options, :enabled, true)
    minimum_external = if use_any?, do: 0, else: 1

    cond do
      not is_integer(external_port) or external_port not in minimum_external..65_535 ->
        {:error, :invalid_external_port}

      not is_integer(internal_port) or internal_port not in 1..65_535 ->
        {:error, :invalid_internal_port}

      protocol not in [:tcp, :udp] ->
        {:error, :invalid_protocol}

      not is_integer(lease_duration) or lease_duration not in 0..4_294_967_295 ->
        {:error, :invalid_lease_duration}

      not is_binary(description) or not String.valid?(description) ->
        {:error, :invalid_description}

      not is_binary(remote_host) or not String.valid?(remote_host) ->
        {:error, :invalid_remote_host}

      not is_boolean(enabled) ->
        {:error, :invalid_enabled}

      not is_pid(Keyword.get(options, :owner, self())) ->
        {:error, :invalid_owner}

      true ->
        :ok
    end
  end

  defp start_lease(gateway, mapping, owner, renew_options) do
    case Lease.start(
           gateway,
           mapping,
           owner: owner,
           clock: gateway.options.clock,
           action_options: renew_options
         ) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, reason} ->
        cleanup =
          delete_port_mapping(
            gateway,
            mapping.external_port,
            mapping.protocol
          )

        {:error, {:lease_start_failed, reason, cleanup}}
    end
  end

  defp internal_client(gateway, options) do
    case Keyword.get(options, :internal_client) do
      nil -> default_internal_client(gateway)
      address -> normalize_address(address)
    end
  end

  defp default_internal_client(%__MODULE__{local_address: address}) when not is_nil(address),
    do: {:ok, address_to_string(address)}

  defp default_internal_client(gateway) do
    with %URI{} = control_url <- gateway.wan_service.description.control_url,
         {:ok, address} <-
           Network.local_address_for(gateway.options.network_adapter, control_url),
         address when address != {0, 0, 0, 0} <- address do
      {:ok, address_to_string(address)}
    else
      _reason -> {:error, :no_internal_client}
    end
  end

  defp normalize_address({_, _, _, _} = address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> {:error, :invalid_internal_client}
      value -> {:ok, List.to_string(value)}
    end
  end

  defp normalize_address(address) when is_binary(address) do
    case parse_address(address) do
      {:ok, {_, _, _, _} = parsed} -> {:ok, address_to_string(parsed)}
      _result -> {:error, :invalid_internal_client}
    end
  end

  defp normalize_address(_address), do: {:error, :invalid_internal_client}

  defp invoke_add(gateway, mapping, false, options) do
    case Service.invoke(
           gateway.wan_service,
           "AddPortMapping",
           add_arguments(mapping),
           options
         ) do
      {:ok, _result} -> {:ok, mapping}
      {:error, _reason} = error -> error
    end
  end

  defp invoke_add(gateway, mapping, true, options) do
    with {:ok, result} <-
           Service.invoke(
             gateway.wan_service,
             "AddAnyPortMapping",
             add_arguments(mapping),
             options
           ),
         {:ok, granted} <-
           parse_port(ActionResult.get(result, "NewReservedPort"), :reserved_port) do
      {:ok, %{mapping | external_port: granted}}
    end
  end

  defp add_arguments(mapping) do
    [
      {"NewRemoteHost", mapping.remote_host},
      {"NewExternalPort", Integer.to_string(mapping.external_port)},
      {"NewProtocol", Protocol.to_wire(mapping.protocol)},
      {"NewInternalPort", Integer.to_string(mapping.internal_port)},
      {"NewInternalClient", mapping.internal_client},
      {"NewEnabled", if(mapping.enabled, do: "1", else: "0")},
      {"NewPortMappingDescription", mapping.description},
      {"NewLeaseDuration", Integer.to_string(mapping.lease_duration)}
    ]
  end

  defp enumerate(_gateway, _options, index, max_entries, mappings)
       when index >= max_entries,
       do: {:ok, Enum.reverse(mappings)}

  defp enumerate(gateway, options, index, max_entries, mappings) do
    case Service.invoke(
           gateway.wan_service,
           "GetGenericPortMappingEntry",
           [{"NewPortMappingIndex", Integer.to_string(index)}],
           action_options(options)
         ) do
      {:ok, result} ->
        case mapping_from_generic(result) do
          {:ok, mapping} ->
            enumerate(gateway, options, index + 1, max_entries, [mapping | mappings])

          {:error, _reason} = error ->
            error
        end

      {:error, {:upnp_error, %UPnP.UpnpError{code: code}}} when code in [713, 714] ->
        {:ok, Enum.reverse(mappings)}

      {:error, _reason} = error ->
        error
    end
  end

  defp mapping_from_generic(result) do
    with {:ok, external_port} <-
           parse_port(ActionResult.get(result, "NewExternalPort"), :external_port),
         {:ok, internal_port} <-
           parse_port(ActionResult.get(result, "NewInternalPort"), :internal_port),
         {:ok, protocol} <-
           Protocol.parse(ActionResult.get(result, "NewProtocol") || ""),
         {:ok, internal_client} <-
           required_string(result, "NewInternalClient") do
      {:ok,
       %Mapping{
         remote_host: ActionResult.get(result, "NewRemoteHost") || "",
         external_port: external_port,
         protocol: protocol,
         internal_port: internal_port,
         internal_client: internal_client,
         enabled: parse_boolean(ActionResult.get(result, "NewEnabled")),
         description: ActionResult.get(result, "NewPortMappingDescription") || "",
         lease_duration: non_negative_integer(ActionResult.get(result, "NewLeaseDuration"), 0)
       }}
    end
  end

  defp mapping_from_specific(result, remote_host, external_port, protocol) do
    with {:ok, internal_port} <-
           parse_port(ActionResult.get(result, "NewInternalPort"), :internal_port),
         {:ok, internal_client} <- required_string(result, "NewInternalClient") do
      {:ok,
       %Mapping{
         remote_host: remote_host,
         external_port: external_port,
         protocol: protocol,
         internal_port: internal_port,
         internal_client: internal_client,
         enabled: parse_boolean(ActionResult.get(result, "NewEnabled")),
         description: ActionResult.get(result, "NewPortMappingDescription") || "",
         lease_duration: non_negative_integer(ActionResult.get(result, "NewLeaseDuration"), 0)
       }}
    end
  end

  defp parse_port(value, field) do
    case integer(value) do
      port when port in 0..65_535 -> {:ok, port}
      _value -> {:error, {:invalid_response, field}}
    end
  end

  defp required_string(result, name) do
    case ActionResult.get(result, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_response, name}}
    end
  end

  defp non_negative_integer(value, fallback) do
    case integer(value) do
      parsed when is_integer(parsed) and parsed >= 0 -> parsed
      _value -> fallback
    end
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _result -> nil
    end
  end

  defp integer(_value), do: nil

  defp parse_boolean(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["1", "true", "yes"]

  defp parse_boolean(_value), do: false

  defp parse_address(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(String.trim(value))) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> {:error, {:invalid_response, :ip_address}}
    end
  end

  defp address_to_string(address), do: address |> :inet.ntoa() |> List.to_string()

  defp routed_local_address(
         %Service{description: %{control_url: %URI{} = control_url}},
         network_adapter
       ) do
    case Network.local_address_for(network_adapter, control_url) do
      {:ok, address} -> usable_address(address)
      {:error, _reason} -> nil
    end
  end

  defp routed_local_address(%Service{}, _network_adapter), do: nil

  defp usable_address({0, 0, 0, 0}), do: nil
  defp usable_address({_, _, _, _} = address), do: address
  defp usable_address(_address), do: nil

  defp same_service_type?(service, expected) do
    case service.description.service_type do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) == String.downcase(expected)

      _value ->
        false
    end
  end

  defp action_options(options), do: Keyword.take(options, [:timeout, :validate])
end
