defmodule UPnP.SSDP.Transport.System do
  @moduledoc "System `:gen_udp` SSDP transport."

  @behaviour UPnP.SSDP.Transport

  @multicast {239, 255, 255, 250}

  @impl true
  def open(_state, interface, options) do
    port = Keyword.get(options, :port, 1900)

    :gen_udp.open(port, [
      :binary,
      active: :once,
      reuseaddr: true,
      ip: {0, 0, 0, 0},
      multicast_if: interface,
      multicast_ttl: 2,
      multicast_loop: false,
      add_membership: {@multicast, interface}
    ])
  end

  @impl true
  def activate(_state, socket), do: :inet.setopts(socket, active: :once)

  @impl true
  def send(_state, socket, address, port, payload),
    do: :gen_udp.send(socket, address, port, payload)

  @impl true
  def close(_state, socket) do
    :gen_udp.close(socket)
    :ok
  end
end
