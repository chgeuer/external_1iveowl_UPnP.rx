defmodule UPnP.SSDP.Interface do
  @moduledoc false

  use GenServer, restart: :transient

  alias UPnP.SSDP
  alias UPnP.SSDP.Transport

  @multicast {239, 255, 255, 250}
  @port 1900
  @max_datagram_bytes 65_507

  def child_spec(options) do
    %{super(options) | id: {__MODULE__, make_ref()}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec search(GenServer.server(), UPnP.SSDP.SearchTarget.t(), keyword()) ::
          :ok | {:error, term()}
  def search(server, target, options) do
    GenServer.call(server, {:search, target, options})
  end

  @impl true
  def init(options) do
    coordinator = Keyword.fetch!(options, :coordinator)
    address = Keyword.fetch!(options, :address)
    transport = Keyword.fetch!(options, :transport)
    clock = Keyword.fetch!(options, :clock)
    port = Keyword.get(options, :port, @port)
    monitor = Process.monitor(coordinator)

    case Transport.open(transport, address, port: port) do
      {:ok, socket} ->
        {:ok,
         %{
           coordinator: coordinator,
           coordinator_monitor: monitor,
           address: address,
           transport: transport,
           clock: clock,
           socket: socket
         }}

      {:error, reason} ->
        {:stop, {:udp_open_failed, address, reason}}
    end
  end

  @impl true
  def handle_call({:search, target, options}, _from, state) do
    repetitions = Keyword.get(options, :repetitions, 2)
    interval = Keyword.get(options, :repeat_interval, 100)

    with {:ok, payload} <- SSDP.m_search(target, options),
         :ok <- Transport.send(state.transport, state.socket, @multicast, @port, payload) do
      if repetitions > 1 do
        UPnP.Clock.send_after(
          state.clock,
          self(),
          {:repeat_search, payload, repetitions - 1, interval},
          interval
        )
      end

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:udp, socket, remote_address, remote_port, datagram},
        %{socket: socket} = state
      ) do
    if byte_size(datagram) <= @max_datagram_bytes do
      case SSDP.parse(datagram) do
        {:ok, envelope} ->
          envelope = %{
            envelope
            | remote_endpoint: {remote_address, remote_port}
          }

          send(state.coordinator, {:ssdp, self(), envelope})

        {:error, reason} ->
          UPnP.Telemetry.emit([:upnp, :ssdp, :parse_error], %{}, %{
            reason: reason,
            interface: state.address
          })
      end
    else
      UPnP.Telemetry.emit(
        [:upnp, :ssdp, :datagram_dropped],
        %{bytes: byte_size(datagram)},
        %{
          reason: :too_large,
          interface: state.address
        }
      )
    end

    case Transport.activate(state.transport, socket) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:udp_activate_failed, reason}, state}
    end
  end

  def handle_info({:udp_error, socket, reason}, %{socket: socket} = state) do
    {:stop, {:udp_error, reason}, state}
  end

  def handle_info({:repeat_search, payload, remaining, interval}, state) do
    case Transport.send(state.transport, state.socket, @multicast, @port, payload) do
      :ok when remaining > 1 ->
        UPnP.Clock.send_after(
          state.clock,
          self(),
          {:repeat_search, payload, remaining - 1, interval},
          interval
        )

        {:noreply, state}

      :ok ->
        {:noreply, state}

      {:error, reason} ->
        UPnP.Telemetry.emit([:upnp, :ssdp, :send_error], %{}, %{
          reason: reason,
          interface: state.address
        })

        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{coordinator_monitor: monitor} = state
      ) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{transport: transport, socket: socket}) do
    Transport.close(transport, socket)
  end

  def terminate(_reason, _state), do: :ok
end
