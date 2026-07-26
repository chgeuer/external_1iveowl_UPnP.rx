defmodule UPnP.IGD.Lease do
  @moduledoc """
  A supervised port-mapping lease handle.

  `close/1` is graceful and deletes the mapping. `abandon/1`, owner death, or
  abrupt process termination only stop renewal; a finite mapping then expires
  on the gateway.
  """

  alias UPnP.IGD.{Gateway, Mapping}

  @enforce_keys [:server, :mapping]
  defstruct [:server, :mapping]

  @type t :: %__MODULE__{server: pid(), mapping: Mapping.t()}

  @doc false
  @spec start(Gateway.t(), Mapping.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def start(%Gateway{} = gateway, %Mapping{} = mapping, options) do
    child_options =
      options
      |> Keyword.put(:gateway, gateway)
      |> Keyword.put(:mapping, mapping)

    case DynamicSupervisor.start_child(
           UPnP.IGD.LeaseSupervisor,
           {UPnP.IGD.Lease.Worker, child_options}
         ) do
      {:ok, pid} -> {:ok, %__MODULE__{server: pid, mapping: mapping}}
      {:error, reason} -> {:error, {:lease_start_failed, reason}}
    end
  end

  @doc """
  Subscribes to renewal lifecycle events.

  Events arrive as `{:upnp, subscription.ref, %UPnP.IGD.LeaseEvent{}}`.
  """
  @spec subscribe(t(), pid()) :: {:ok, UPnP.Subscription.t()}
  def subscribe(%__MODULE__{server: server}, subscriber \\ self()) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @doc "Stops renewal and removes the mapping. The operation is idempotent."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{server: server}) do
    GenServer.call(server, :close, :infinity)
  catch
    :exit, {:noproc, _reason} -> :ok
    :exit, {:normal, _reason} -> :ok
  end

  @doc """
  Stops renewal without a network delete. A finite mapping expires naturally.
  """
  @spec abandon(t()) :: :ok
  def abandon(%__MODULE__{server: server}) do
    GenServer.call(server, :abandon)
  catch
    :exit, {:noproc, _reason} -> :ok
    :exit, {:normal, _reason} -> :ok
  end
end
