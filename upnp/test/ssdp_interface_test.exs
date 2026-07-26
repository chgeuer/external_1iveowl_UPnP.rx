defmodule UPnP.SSDPInterfaceTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.SSDP.{Interface, SearchTarget}

  defmodule FakeTransport do
    @behaviour UPnP.SSDP.Transport

    @impl true
    def open(test_pid, address, _options) do
      socket = make_ref()
      send(test_pid, {:opened, socket, address})
      {:ok, socket}
    end

    @impl true
    def activate(test_pid, socket) do
      send(test_pid, {:activated, socket})
      :ok
    end

    @impl true
    def send(test_pid, socket, address, port, payload) do
      send(test_pid, {:sent, socket, address, port, IO.iodata_to_binary(payload)})
      :ok
    end

    @impl true
    def close(test_pid, socket) do
      send(test_pid, {:closed, socket})
      :ok
    end
  end

  setup do
    {:ok, clock} = start_supervised(Manual)

    {:ok, interface} =
      start_supervised(
        {Interface,
         coordinator: self(),
         address: {192, 0, 2, 10},
         transport: {FakeTransport, self()},
         clock: {Manual, clock}}
      )

    assert_receive {:opened, socket, {192, 0, 2, 10}}
    %{clock: clock, interface: interface, socket: socket}
  end

  test "sends the configured repeated search", %{
    clock: clock,
    interface: interface,
    socket: socket
  } do
    assert :ok =
             Interface.search(interface, SearchTarget.root_device(),
               mx: 1,
               friendly_name: "test",
               repetitions: 2,
               repeat_interval: 100
             )

    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, first}
    assert first =~ "ST: upnp:rootdevice\r\n"

    :ok = Manual.advance(clock, 100)
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, ^first}
  end

  test "parses received datagrams and records route metadata", %{
    interface: interface,
    socket: socket
  } do
    datagram =
      "HTTP/1.1 200 OK\r\n" <>
        "LOCATION: http://192.0.2.1/device.xml\r\n" <>
        "ST: upnp:rootdevice\r\n" <>
        "USN: uuid:device::upnp:rootdevice\r\n\r\n"

    send(interface, {:udp, socket, {192, 0, 2, 1}, 1900, datagram})

    assert_receive {:ssdp, ^interface, envelope}
    assert envelope.local_address == {192, 0, 2, 10}
    assert envelope.remote_endpoint == {{192, 0, 2, 1}, 1900}
    assert_receive {:activated, ^socket}
  end
end
