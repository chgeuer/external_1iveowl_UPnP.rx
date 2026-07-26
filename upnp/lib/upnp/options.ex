defmodule UPnP.Options do
  @moduledoc """
  Immutable control-point configuration.
  """

  alias UPnP.SSDP.SearchTarget

  defstruct interfaces: :auto,
            clock: UPnP.Clock.System,
            udp_transport: UPnP.SSDP.Transport.System,
            http_adapter: {UPnP.HTTP.Finch, [name: UPnP.Finch]},
            network_adapter: UPnP.Network.System,
            default_search_target: nil,
            default_mx: 3,
            friendly_name: "UPnP",
            description_timeout: 30_000,
            action_timeout: 30_000,
            event_transport: UPnP.Eventing.Transport.HTTP,
            event_callback_bind: :any,
            event_callback_port: 0,
            event_callback_host: nil,
            event_callback_base_url: nil,
            event_callback_acceptors: 2,
            event_subscription_timeout: 1_800_000,
            event_retry_backoff: [1_000, 2_000, 5_000, 10_000],
            max_event_body_bytes: 1_048_576,
            auto_resubscribe: true,
            roster_expiry_fallback: 1_800_000,
            max_document_bytes: 2_097_152,
            search_repetitions: 2,
            search_repeat_interval: 100

  @type t :: %__MODULE__{
          interfaces: :auto | [:inet.ip4_address()],
          clock: UPnP.Clock.t(),
          udp_transport: UPnP.SSDP.Transport.adapter(),
          http_adapter: UPnP.HTTP.adapter(),
          network_adapter: UPnP.Network.adapter(),
          default_search_target: SearchTarget.t(),
          default_mx: 1..5,
          friendly_name: String.t(),
          description_timeout: pos_integer(),
          action_timeout: pos_integer(),
          event_transport: UPnP.Eventing.Transport.adapter(),
          event_callback_bind: :any | :loopback | :inet.ip_address(),
          event_callback_port: :inet.port_number(),
          event_callback_host: nil | :auto | String.t() | :inet.ip_address(),
          event_callback_base_url: nil | String.t() | URI.t(),
          event_callback_acceptors: pos_integer(),
          event_subscription_timeout: pos_integer(),
          event_retry_backoff: [non_neg_integer()],
          max_event_body_bytes: pos_integer(),
          auto_resubscribe: boolean(),
          roster_expiry_fallback: pos_integer(),
          max_document_bytes: pos_integer(),
          search_repetitions: pos_integer(),
          search_repeat_interval: non_neg_integer()
        }

  @doc "Builds and validates options from a keyword list or existing struct."
  @spec new(keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = options), do: validate(options)

  def new(options) when is_list(options) do
    known = Map.keys(%__MODULE__{}) -- [:__struct__]

    with :ok <- validate_keys(options, known) do
      defaults = %__MODULE__{default_search_target: SearchTarget.root_device()}

      options =
        Enum.reduce(options, defaults, fn {key, value}, acc -> Map.replace!(acc, key, value) end)

      validate(options)
    end
  end

  defp validate_keys(options, known) do
    case Keyword.keys(options) -- known do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp validate(options) do
    cond do
      options.interfaces != :auto and not valid_interfaces?(options.interfaces) ->
        {:error, :invalid_interfaces}

      not valid_adapter?(options.network_adapter) ->
        {:error, :invalid_network_adapter}

      not match?(%SearchTarget{}, options.default_search_target) ->
        {:error, :invalid_default_search_target}

      options.default_mx not in 1..5 ->
        {:error, :invalid_default_mx}

      not valid_header?(options.friendly_name) ->
        {:error, :invalid_friendly_name}

      not positive?(options.description_timeout) or not positive?(options.action_timeout) ->
        {:error, :invalid_timeout}

      not is_integer(options.event_callback_port) or options.event_callback_port not in 0..65_535 ->
        {:error, :invalid_event_callback_port}

      not valid_adapter?(options.event_transport) ->
        {:error, :invalid_event_transport}

      not valid_callback_bind?(options.event_callback_bind) ->
        {:error, :invalid_event_callback_bind}

      not valid_callback_host?(options.event_callback_host) ->
        {:error, :invalid_event_callback_host}

      not valid_callback_base_url?(options.event_callback_base_url) ->
        {:error, :invalid_event_callback_base_url}

      not positive?(options.event_callback_acceptors) ->
        {:error, :invalid_event_callback_acceptors}

      not positive?(options.event_subscription_timeout) or
          not positive?(options.roster_expiry_fallback) ->
        {:error, :invalid_timeout}

      not valid_retry_backoff?(options.event_retry_backoff) ->
        {:error, :invalid_event_retry_backoff}

      not positive?(options.max_event_body_bytes) ->
        {:error, :invalid_max_event_body_bytes}

      not positive?(options.max_document_bytes) ->
        {:error, :invalid_max_document_bytes}

      not positive?(options.search_repetitions) or
        not is_integer(options.search_repeat_interval) or options.search_repeat_interval < 0 ->
        {:error, :invalid_search_repetition}

      true ->
        {:ok, options}
    end
  end

  defp valid_interfaces?(interfaces) when is_list(interfaces),
    do: Enum.all?(interfaces, &valid_ipv4?/1)

  defp valid_interfaces?(_interfaces), do: false

  defp valid_ipv4?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..255))

  defp valid_ipv4?(_address), do: false

  defp valid_ip?(address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> false
      _characters -> true
    end
  end

  defp valid_adapter?(module) when is_atom(module), do: true
  defp valid_adapter?({module, _state}) when is_atom(module), do: true
  defp valid_adapter?(_adapter), do: false

  defp valid_callback_bind?(bind) when bind in [:any, :loopback], do: true
  defp valid_callback_bind?(bind) when is_tuple(bind), do: valid_ip?(bind)
  defp valid_callback_bind?(_bind), do: false

  defp valid_callback_host?(host) when host in [nil, :auto], do: true

  defp valid_callback_host?(host) when is_binary(host),
    do: String.trim(host) != "" and valid_header?(host)

  defp valid_callback_host?(host) when is_tuple(host), do: valid_ip?(host)
  defp valid_callback_host?(_host), do: false

  defp valid_callback_base_url?(nil), do: true

  defp valid_callback_base_url?(value) when is_binary(value),
    do: value |> URI.parse() |> valid_callback_base_url?()

  defp valid_callback_base_url?(%URI{scheme: scheme, host: host}),
    do:
      is_binary(scheme) and String.downcase(scheme) in ["http", "https"] and
        is_binary(host) and host != ""

  defp valid_callback_base_url?(_value), do: false

  defp valid_retry_backoff?(backoff) when is_list(backoff),
    do: Enum.all?(backoff, &(is_integer(&1) and &1 >= 0))

  defp valid_retry_backoff?(_backoff), do: false

  defp valid_header?(value),
    do: is_binary(value) and value != "" and not String.contains?(value, ["\r", "\n"])

  defp positive?(value), do: is_integer(value) and value > 0
end
