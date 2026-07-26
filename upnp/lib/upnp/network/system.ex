defmodule UPnP.Network.System do
  @moduledoc """
  Kernel-backed network route Adapter.

  A UDP connect asks the kernel to select a route without sending a packet.
  """

  @behaviour UPnP.Network

  @impl true
  def local_address_for(%URI{host: host} = uri, _state) when is_binary(host) do
    with {:ok, port} <- port(uri),
         {:ok, remote_address} <- :inet.getaddr(String.to_charlist(host), :inet),
         {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]),
         result <- route(socket, remote_address, port) do
      :gen_udp.close(socket)
      result
    end
  end

  def local_address_for(_uri, _state), do: {:error, :missing_host}

  defp route(socket, remote_address, port) do
    with :ok <- :gen_udp.connect(socket, remote_address, port),
         {:ok, {local_address, _port}} <- :inet.sockname(socket) do
      {:ok, local_address}
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_scheme), do: nil

  defp port(%URI{port: port}) when is_integer(port), do: {:ok, port}

  defp port(%URI{scheme: scheme}) do
    case default_port(scheme) do
      nil -> {:error, :missing_port}
      port -> {:ok, port}
    end
  end
end
