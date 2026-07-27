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

  defmodule FailingTransport do
    @behaviour UPnP.SSDP.Transport

    @impl true
    def open({test_pid, mode}, address, _options) do
      socket = make_ref()
      send(test_pid, {:opened, socket, address})
      {:ok, {socket, mode}}
    end

    @impl true
    def activate({_test_pid, :activate}, _socket), do: {:error, :activation_failed}

    def activate({test_pid, _mode}, socket) do
      send(test_pid, {:activated, socket})
      :ok
    end

    @impl true
    def send({_test_pid, :send}, _socket, _address, _port, _payload),
      do: {:error, :send_failed}

    def send({test_pid, _mode}, socket, address, port, payload) do
      send(test_pid, {:sent, socket, address, port, IO.iodata_to_binary(payload)})
      :ok
    end

    @impl true
    def close(test_pid_and_mode, socket) do
      {test_pid, _mode} = test_pid_and_mode
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
               repetitions: 3,
               repeat_interval: 100
             )

    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, first}
    assert first =~ "ST: upnp:rootdevice\r\n"

    :ok = Manual.advance(clock, 100)
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, ^first}

    # The transport reports the send before the handler schedules its next timer.
    _state = :sys.get_state(interface)
    :ok = Manual.advance(clock, 100)
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, ^first}
  end

  test "search composition and transport failures remain tagged", %{
    clock: clock,
    interface: interface
  } do
    assert Interface.search(interface, SearchTarget.root_device(), mx: 0) ==
             {:error, :invalid_mx}

    failing =
      start_supervised!(
        {Interface,
         coordinator: self(),
         address: {192, 0, 2, 11},
         transport: {FailingTransport, {self(), :send}},
         clock: {Manual, clock}},
        id: :send_failing_interface
      )

    assert_receive {:opened, _socket, {192, 0, 2, 11}}

    assert Interface.search(failing, SearchTarget.root_device(), mx: 1) ==
             {:error, :send_failed}
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

  test "survives a received datagram with an invalid UTF-8 location", %{
    interface: interface,
    socket: socket
  } do
    datagram =
      "NOTIFY * HTTP/1.1\r\n" <>
        "NT: upnp:rootdevice\r\n" <>
        "NTS: ssdp:alive\r\n" <>
        "USN: uuid:hostile::upnp:rootdevice\r\n" <>
        <<"LOCATION: http://", 0xFF, 0xFE, "/device.xml\r\n\r\n">>

    send(interface, {:udp, socket, {192, 0, 2, 1}, 1900, datagram})

    assert_receive {:ssdp, ^interface, envelope}
    assert envelope.location == nil
    assert envelope.parsing_error?
    assert_receive {:activated, ^socket}
    assert Process.alive?(interface)
  end

  test "malformed datagrams are dropped and receive activation failures stop the worker", %{
    clock: clock
  } do
    interface =
      start_supervised!(
        {Interface,
         coordinator: self(),
         address: {192, 0, 2, 12},
         transport: {FailingTransport, {self(), :activate}},
         clock: {Manual, clock}},
        id: :activation_failing_interface
      )

    assert_receive {:opened, socket, {192, 0, 2, 12}}
    monitor = Process.monitor(interface)
    send(interface, {:udp, {socket, :activate}, {192, 0, 2, 1}, 1900, "not SSDP"})

    assert_receive {:closed, {^socket, :activate}}

    assert_receive {:DOWN, ^monitor, :process, ^interface,
                    {:udp_activate_failed, :activation_failed}},
                   1_000
  end

  test "UDP transport errors stop the affected interface", %{interface: interface, socket: socket} do
    monitor = Process.monitor(interface)
    send(interface, {:udp_error, socket, :closed})
    assert_receive {:DOWN, ^monitor, :process, ^interface, {:udp_error, :closed}}
  end
end
