defmodule UPnP.Eventing.CallbackServer do
  @moduledoc """
  A manager-owned Bandit callback listener.

  The listener is dynamically supervised and monitors its manager so an abrupt
  manager exit cannot leave an orphaned inbound server.
  """

  use GenServer

  @type info :: %{
          pid: pid(),
          bandit: pid(),
          address: :inet.socket_address(),
          port: :inet.port_number()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Starts a callback server linked to its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Returns the listener's actual bound address and port."
  @spec info(GenServer.server()) :: info()
  def info(server), do: GenServer.call(server, :info)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    manager = Keyword.fetch!(options, :manager)
    manager_monitor = Process.monitor(manager)

    bandit_options = [
      plug: {UPnP.Eventing.CallbackPlug, Keyword.fetch!(options, :plug_options)},
      ip: Keyword.get(options, :bind, :any),
      port: Keyword.get(options, :port, 0),
      startup_log: false,
      http_2_options: [enabled: false],
      thousand_island_options: [num_acceptors: Keyword.get(options, :acceptors, 2)]
    ]

    case Bandit.start_link(bandit_options) do
      {:ok, bandit} ->
        case ThousandIsland.listener_info(bandit) do
          {:ok, {address, port}} ->
            {:ok,
             %{
               manager: manager,
               manager_monitor: manager_monitor,
               bandit: bandit,
               address: address,
               port: port
             }}

          :error ->
            Supervisor.stop(bandit)
            {:stop, :listener_info_unavailable}
        end

      {:error, reason} ->
        {:stop, {:bandit_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, %{pid: self(), bandit: state.bandit, address: state.address, port: state.port},
     state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{manager_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, bandit, reason}, %{bandit: bandit} = state) do
    {:stop, {:bandit_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.bandit) do
      Process.unlink(state.bandit)

      try do
        Supervisor.stop(state.bandit, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
