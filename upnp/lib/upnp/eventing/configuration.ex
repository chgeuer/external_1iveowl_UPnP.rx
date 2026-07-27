defmodule UPnP.Eventing.Configuration do
  @moduledoc false

  alias UPnP.Network

  @default_timeout 1_800_000
  @default_retry_backoff [1_000, 2_000, 5_000, 10_000]

  @manager_options [
    :owner,
    :control_point,
    :control_point_owner,
    :control_point_generation,
    :clock,
    :transport,
    :transport_options,
    :http_adapter,
    :network_adapter,
    :task_supervisor,
    :subscription_supervisor,
    :server_supervisor,
    :callback_bind,
    :callback_port,
    :callback_host,
    :callback_base_url,
    :callback_scheme,
    :callback_path,
    :callback_acceptors,
    :subscription_timeout,
    :operation_timeout,
    :retry_backoff,
    :max_callback_body_bytes,
    :auto_resubscribe,
    :max_early_notifications
  ]

  @subscription_options [:callback_host, :facing_url, :local_address]

  defstruct owner: nil,
            control_point_owner: nil,
            control_point_generation: nil,
            clock: UPnP.Clock.System,
            transport: UPnP.Eventing.Transport.HTTP,
            transport_options: [],
            callback_bind: :any,
            callback_port: 0,
            callback_host: nil,
            callback_scheme: "http",
            callback_base_url: nil,
            path_prefix: ["upnp", "events"],
            max_body_bytes: 1_048_576,
            operation_timeout: 30_000,
            callback_acceptors: 2,
            subscription_timeout: @default_timeout,
            auto_resubscribe: true,
            retry_backoff: @default_retry_backoff,
            max_early_notifications: 32,
            task_supervisor: nil,
            subscription_supervisor: nil,
            server_supervisor: nil,
            network_adapter: UPnP.Network.System

  @type t :: %__MODULE__{
          owner: GenServer.server() | nil,
          control_point_owner: pid() | nil,
          control_point_generation: pid() | nil,
          clock: UPnP.Clock.t(),
          transport: UPnP.Eventing.Transport.adapter(),
          transport_options: keyword(),
          callback_bind: :any | :loopback | :inet.ip_address(),
          callback_port: :inet.port_number(),
          callback_host: nil | :auto | :loopback | String.t() | :inet.ip_address(),
          callback_scheme: String.t(),
          callback_base_url: URI.t() | nil,
          path_prefix: [String.t()],
          max_body_bytes: pos_integer(),
          operation_timeout: pos_integer(),
          callback_acceptors: pos_integer(),
          subscription_timeout: pos_integer(),
          auto_resubscribe: boolean(),
          retry_backoff: [non_neg_integer()],
          max_early_notifications: non_neg_integer(),
          task_supervisor: GenServer.server(),
          subscription_supervisor: GenServer.server(),
          server_supervisor: GenServer.server(),
          network_adapter: UPnP.Network.adapter()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(options) when is_list(options) do
    with :ok <- validate_keys(options, @manager_options),
         {:ok, callback_scheme} <-
           normalize_scheme(Keyword.get(options, :callback_scheme, "http")),
         {:ok, callback_base_url} <-
           parse_optional_uri(Keyword.get(options, :callback_base_url)),
         {:ok, path_prefix} <- path_prefix(options, callback_base_url),
         {:ok, transport_options} <- transport_options(options) do
      options
      |> build(callback_scheme, callback_base_url, path_prefix, transport_options)
      |> validate()
    end
  end

  def new(_options), do: {:error, :invalid_options}

  @spec callback_origin(t(), URI.t(), :inet.port_number(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def callback_origin(%__MODULE__{} = config, %URI{} = event_url, callback_port, options)
      when is_list(options) do
    with :ok <- validate_keys(options, @subscription_options) do
      case Keyword.get(options, :facing_url) || config.callback_base_url do
        nil ->
          routed_origin(config, event_url, callback_port, options)

        facing_url ->
          case parse_optional_uri(facing_url) do
            {:ok, %URI{} = uri} -> {:ok, uri}
            _error -> {:error, :invalid_facing_url}
          end
      end
    end
  end

  @spec callback_url(t(), URI.t(), String.t(), String.t()) :: URI.t()
  def callback_url(%__MODULE__{} = config, %URI{} = origin, manager_token, callback_token)
      when is_binary(manager_token) and is_binary(callback_token) do
    path =
      "/" <>
        Enum.join(
          config.path_prefix ++ [manager_token, callback_token],
          "/"
        )

    %{origin | path: path, query: nil, fragment: nil, userinfo: nil}
  end

  defp build(options, callback_scheme, callback_base_url, path_prefix, transport_options) do
    %__MODULE__{
      owner: Keyword.get(options, :owner),
      control_point_owner: Keyword.get(options, :control_point_owner),
      control_point_generation: Keyword.get(options, :control_point_generation),
      clock: Keyword.get(options, :clock, UPnP.Clock.System),
      transport: Keyword.get(options, :transport, UPnP.Eventing.Transport.HTTP),
      transport_options: transport_options,
      callback_bind: Keyword.get(options, :callback_bind, :any),
      callback_port: Keyword.get(options, :callback_port, 0),
      callback_host: Keyword.get(options, :callback_host),
      callback_scheme: callback_scheme,
      callback_base_url: callback_base_url,
      path_prefix: path_prefix,
      max_body_bytes: Keyword.get(options, :max_callback_body_bytes, 1_048_576),
      operation_timeout: Keyword.get(options, :operation_timeout, 30_000),
      callback_acceptors: Keyword.get(options, :callback_acceptors, 2),
      subscription_timeout: Keyword.get(options, :subscription_timeout, @default_timeout),
      auto_resubscribe: Keyword.get(options, :auto_resubscribe, true),
      retry_backoff: Keyword.get(options, :retry_backoff, @default_retry_backoff),
      max_early_notifications: Keyword.get(options, :max_early_notifications, 32),
      task_supervisor: Keyword.get(options, :task_supervisor),
      subscription_supervisor: Keyword.get(options, :subscription_supervisor),
      server_supervisor: Keyword.get(options, :server_supervisor),
      network_adapter: Keyword.get(options, :network_adapter, UPnP.Network.System)
    }
  end

  defp validate(config) do
    cond do
      not positive?(config.subscription_timeout) ->
        {:error, :invalid_subscription_timeout}

      not is_integer(config.callback_port) or config.callback_port not in 0..65_535 ->
        {:error, :invalid_callback_port}

      not valid_callback_bind?(config.callback_bind) ->
        {:error, :invalid_callback_bind}

      not valid_callback_host?(config.callback_host) ->
        {:error, :invalid_callback_host}

      not positive?(config.max_body_bytes) ->
        {:error, :invalid_max_callback_body_bytes}

      not positive?(config.operation_timeout) ->
        {:error, :invalid_operation_timeout}

      not valid_retry_backoff?(config.retry_backoff) ->
        {:error, :invalid_retry_backoff}

      not is_boolean(config.auto_resubscribe) ->
        {:error, :invalid_auto_resubscribe}

      not is_integer(config.max_early_notifications) or config.max_early_notifications < 0 ->
        {:error, :invalid_max_early_notifications}

      not positive?(config.callback_acceptors) ->
        {:error, :invalid_callback_acceptors}

      not valid_adapter?(config.network_adapter) ->
        {:error, :invalid_network_adapter}

      is_nil(config.task_supervisor) ->
        {:error, :missing_task_supervisor}

      is_nil(config.subscription_supervisor) ->
        {:error, :missing_subscription_supervisor}

      is_nil(config.server_supervisor) ->
        {:error, :missing_server_supervisor}

      true ->
        {:ok, config}
    end
  end

  defp routed_origin(config, event_url, callback_port, options) do
    with {:ok, host} <- callback_host(config, event_url, options) do
      {:ok,
       %URI{
         scheme: config.callback_scheme,
         host: host,
         port: callback_port
       }}
    end
  end

  defp callback_host(config, event_url, options) do
    explicit =
      Keyword.get(options, :callback_host) ||
        Keyword.get(options, :local_address) ||
        config.callback_host

    cond do
      explicit not in [nil, :auto] ->
        normalize_host(explicit)

      usable_bind?(config.callback_bind) ->
        normalize_host(config.callback_bind)

      true ->
        route_address(config.network_adapter, event_url)
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

  defp transport_options(options) do
    transport_options = Keyword.get(options, :transport_options, [])

    if Keyword.keyword?(transport_options) do
      case Keyword.fetch(options, :http_adapter) do
        {:ok, adapter} ->
          {:ok, Keyword.put(transport_options, :http_adapter, adapter)}

        :error ->
          {:ok,
           Keyword.put_new(
             transport_options,
             :http_adapter,
             {UPnP.HTTP.Finch, [name: UPnP.Finch]}
           )}
      end
    else
      {:error, :invalid_transport_options}
    end
  end

  defp path_prefix(options, callback_base_url) do
    callback_path =
      case Keyword.fetch(options, :callback_path) do
        {:ok, path} -> path
        :error -> callback_path(callback_base_url)
      end

    if is_binary(callback_path) do
      {:ok, path_segments(callback_path)}
    else
      {:error, :invalid_callback_path}
    end
  end

  defp callback_path(%URI{path: path}) when is_binary(path) and path not in ["", "/"], do: path
  defp callback_path(_callback_base_url), do: "/upnp/events"

  defp path_segments(path) do
    case String.split(path, "/", trim: true) do
      [] -> ["upnp", "events"]
      segments -> segments
    end
  end

  defp normalize_scheme(scheme) when is_binary(scheme) do
    case String.downcase(scheme) do
      scheme when scheme in ["http", "https"] -> {:ok, scheme}
      _scheme -> {:error, :invalid_callback_scheme}
    end
  end

  defp normalize_scheme(scheme) when is_atom(scheme),
    do: scheme |> Atom.to_string() |> normalize_scheme()

  defp normalize_scheme(_scheme), do: {:error, :invalid_callback_scheme}

  defp parse_optional_uri(nil), do: {:ok, nil}
  defp parse_optional_uri(%URI{} = uri), do: normalize_facing_uri(uri)

  defp parse_optional_uri(value) when is_binary(value),
    do: value |> URI.parse() |> normalize_facing_uri()

  defp parse_optional_uri(_value), do: {:error, :invalid_callback_base_url}

  defp normalize_facing_uri(%URI{scheme: scheme, host: host} = uri)
       when is_binary(scheme) and is_binary(host) and host != "" do
    with {:ok, scheme} <- normalize_scheme(scheme),
         false <- String.contains?(host, ["\r", "\n"]) do
      {:ok, %{uri | scheme: scheme, authority: nil, userinfo: nil, host: String.downcase(host)}}
    else
      _error -> {:error, :invalid_callback_base_url}
    end
  end

  defp normalize_facing_uri(_uri), do: {:error, :invalid_callback_base_url}

  defp normalize_host(address) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, reason} -> {:error, {:invalid_callback_host, reason}}
      characters -> {:ok, List.to_string(characters)}
    end
  end

  defp normalize_host(:loopback), do: {:ok, "127.0.0.1"}

  defp normalize_host(host) when is_binary(host) do
    case String.trim(host) do
      "" ->
        {:error, :invalid_callback_host}

      trimmed ->
        if String.contains?(trimmed, ["\r", "\n"]),
          do: {:error, :invalid_callback_host},
          else: {:ok, String.trim(trimmed, "[]")}
    end
  end

  defp normalize_host(_host), do: {:error, :invalid_callback_host}

  defp validate_keys(options, known) do
    if Keyword.keyword?(options) do
      case Enum.uniq(Keyword.keys(options)) -- known do
        [] -> :ok
        unknown -> {:error, {:unknown_options, unknown}}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp valid_callback_bind?(bind) when bind in [:any, :loopback], do: true
  defp valid_callback_bind?(bind) when is_tuple(bind), do: valid_ip?(bind)
  defp valid_callback_bind?(_bind), do: false

  defp valid_callback_host?(host) when host in [nil, :auto], do: true
  defp valid_callback_host?(host), do: match?({:ok, _host}, normalize_host(host))

  defp valid_ip?(address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> false
      _characters -> true
    end
  end

  defp usable_bind?({0, 0, 0, 0}), do: false
  defp usable_bind?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp usable_bind?(:loopback), do: true
  defp usable_bind?(address) when is_tuple(address), do: true
  defp usable_bind?(_address), do: false

  defp valid_retry_backoff?(backoff) when is_list(backoff),
    do: Enum.all?(backoff, &(is_integer(&1) and &1 >= 0))

  defp valid_retry_backoff?(_backoff), do: false

  defp valid_adapter?(module) when is_atom(module) and not is_nil(module), do: true
  defp valid_adapter?({module, _state}) when is_atom(module) and not is_nil(module), do: true
  defp valid_adapter?(_adapter), do: false

  defp positive?(value), do: is_integer(value) and value > 0
end
