defmodule UPnP.Service do
  @moduledoc """
  A service description bound to the control point that can operate it.
  """

  alias UPnP.{ActionDescription, ArgumentDescription, ControlPoint, SCPD, ServiceDescription}

  @enforce_keys [:control_point, :description, :cache_scope]
  defstruct [:control_point, :description, :cache_scope, :local_address]

  @type t :: %__MODULE__{
          control_point: GenServer.server(),
          description: ServiceDescription.t(),
          cache_scope: term(),
          local_address: :inet.ip4_address() | nil
        }

  @doc false
  @spec new(
          GenServer.server(),
          ServiceDescription.t(),
          term(),
          :inet.ip4_address() | nil
        ) :: t()
  def new(control_point, %ServiceDescription{} = description, cache_scope, local_address \\ nil) do
    %__MODULE__{
      control_point: control_point,
      description: description,
      cache_scope: cache_scope,
      local_address: local_address
    }
  end

  @doc "Fetches and caches this service's SCPD."
  @spec get_scpd(t()) :: {:ok, SCPD.t()} | {:error, term()}
  def get_scpd(%__MODULE__{} = service) do
    ControlPoint.get_scpd(
      service.control_point,
      service.description,
      service.cache_scope
    )
  end

  @doc """
  Invokes a SOAP action.

  By default the action and input arguments are checked against the SCPD and
  map arguments are emitted in the wire order declared there. Set
  `validate: false` only for a device whose SCPD is known to be incomplete.
  """
  @spec invoke(t(), binary(), UPnP.SOAP.Composer.arguments(), keyword()) ::
          {:ok, UPnP.ActionResult.t()} | {:error, term()}
  def invoke(service, action_name, arguments \\ [], options \\ [])

  def invoke(%__MODULE__{} = service, action_name, arguments, options)
      when is_binary(action_name) and is_list(options) do
    with {:ok, ordered_arguments} <-
           prepare_arguments(service, action_name, arguments, options) do
      ControlPoint.invoke_action(
        service.control_point,
        service.description,
        action_name,
        ordered_arguments,
        options
      )
    end
  end

  @doc """
  Subscribes to this service's shared GENA event stream.

  The returned property snapshot and live subscription are installed atomically.
  Live `UPnP.Eventing.Event` and `UPnP.Eventing.Lifecycle` values arrive as
  `{:upnp, subscription.ref, event}`.
  """
  @spec subscribe(t(), keyword()) ::
          {:ok, UPnP.Subscription.t(), [UPnP.EventedProperty.t()]} | {:error, term()}
  def subscribe(%__MODULE__{} = service, options \\ []) do
    case service.description.event_sub_url do
      %URI{} = event_sub_url ->
        options =
          if service.local_address && not Keyword.has_key?(options, :local_address) do
            Keyword.put(options, :local_address, service.local_address)
          else
            options
          end

        ControlPoint.subscribe_events(service.control_point, event_sub_url, options)

      _event_sub_url ->
        {:error, :missing_event_sub_url}
    end
  end

  defp prepare_arguments(service, action_name, arguments, options) do
    if Keyword.get(options, :validate, true) do
      with {:ok, scpd} <- get_scpd(service),
           {:ok, action} <- find_action(scpd, action_name),
           {:ok, given} <- normalize_arguments(arguments) do
        order_arguments(action, given)
      end
    else
      {:ok, arguments}
    end
  end

  defp find_action(%SCPD{actions: actions}, action_name) do
    normalized = normalize(action_name)

    case Enum.find(actions, fn
           %ActionDescription{name: name} when is_binary(name) -> normalize(name) == normalized
           _action -> false
         end) do
      nil -> {:error, {:unknown_action, action_name}}
      action -> {:ok, action}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) and not is_struct(arguments),
    do: normalize_arguments(Map.to_list(arguments))

  defp normalize_arguments(arguments) when is_list(arguments) do
    Enum.reduce_while(arguments, {:ok, %{}}, fn
      {name, value}, {:ok, result} when is_binary(name) and is_binary(value) ->
        key = normalize(name)

        if Map.has_key?(result, key) do
          {:halt, {:error, {:duplicate_argument, name}}}
        else
          {:cont, {:ok, Map.put(result, key, {name, value})}}
        end

      _argument, _result ->
        {:halt, {:error, :invalid_arguments}}
    end)
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp order_arguments(%ActionDescription{arguments: arguments}, given) do
    expected =
      Enum.filter(arguments, fn
        %ArgumentDescription{direction: :in, name: name} when is_binary(name) -> true
        _argument -> false
      end)

    expected_keys = MapSet.new(expected, &normalize(&1.name))
    unknown = Map.keys(given) |> Enum.reject(&MapSet.member?(expected_keys, &1))

    cond do
      unknown != [] ->
        {_original, _value} = given[hd(unknown)]
        {:error, {:unknown_argument, elem(given[hd(unknown)], 0)}}

      true ->
        Enum.reduce_while(expected, {:ok, []}, fn argument, {:ok, ordered} ->
          case given[normalize(argument.name)] do
            nil ->
              {:halt, {:error, {:missing_argument, argument.name}}}

            {_original_name, value} ->
              {:cont, {:ok, [{argument.name, value} | ordered]}}
          end
        end)
        |> case do
          {:ok, ordered} -> {:ok, Enum.reverse(ordered)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
