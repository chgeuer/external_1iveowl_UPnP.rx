defmodule UPnP.TelemetryTest do
  use ExUnit.Case, async: false

  alias UPnP.Clock.Manual
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.SSDP.Interface
  alias UPnP.{Action, ControlPoint, Options, ServiceDescription, Telemetry}

  @events [
    [:upnp, :ssdp, :interface_error],
    [:upnp, :ssdp, :parse_error],
    [:upnp, :ssdp, :datagram_dropped],
    [:upnp, :ssdp, :send_error],
    [:upnp, :roster, :change],
    [:upnp, :description, :fetch],
    [:upnp, :action, :invoke],
    [:upnp, :eventing, :notification],
    [:upnp, :eventing, :lifecycle],
    [:upnp, :igd, :lease]
  ]

  defmodule FakeTransport do
    @behaviour UPnP.SSDP.Transport

    @impl true
    def open(test_pid, address, _options) do
      socket = make_ref()
      Kernel.send(test_pid, {:opened, socket, address})
      {:ok, socket}
    end

    @impl true
    def activate(test_pid, socket) do
      Kernel.send(test_pid, {:activated, socket})
      :ok
    end

    @impl true
    def send(_test_pid, _socket, _address, _port, _payload), do: :ok

    @impl true
    def close(_test_pid, _socket), do: :ok
  end

  defmodule FakeHTTP do
    @behaviour UPnP.HTTP

    @impl true
    def request(%Request{}, options), do: Keyword.fetch!(options, :result)
  end

  setup do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.forward_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "advertises stable event names" do
    assert Telemetry.events() == @events
  end

  test "every advertised event emits its documented contract keys" do
    samples = [
      {[:upnp, :ssdp, :interface_error], %{}, %{interface: {192, 0, 2, 10}, reason: :error}},
      {[:upnp, :ssdp, :parse_error], %{}, %{interface: {192, 0, 2, 10}, reason: :empty}},
      {[:upnp, :ssdp, :datagram_dropped], %{bytes: 65_508},
       %{interface: {192, 0, 2, 10}, reason: :too_large}},
      {[:upnp, :ssdp, :send_error], %{}, %{interface: {192, 0, 2, 10}, reason: :ehostunreach}},
      {[:upnp, :roster, :change], %{}, %{identity: "uuid:device", kind: :appeared}},
      {[:upnp, :description, :fetch], %{},
       %{location: "http://192.0.2.1/device.xml", outcome: :ok}},
      {[:upnp, :action, :invoke], %{},
       %{action: "GetStatusInfo", outcome: :ok, service_type: "urn:example"}},
      {[:upnp, :eventing, :notification], %{property_count: 2},
       %{sequence: 1, sid: "uuid:sid", subscription: "http://192.0.2.1/events"}},
      {[:upnp, :eventing, :lifecycle], %{},
       %{
         kind: :subscribed,
         reason: nil,
         sid: "uuid:sid",
         subscription: "http://192.0.2.1/events"
       }},
      {[:upnp, :igd, :lease], %{},
       %{external_port: 8080, kind: :renewed, protocol: :tcp, reason: nil}}
    ]

    assert Enum.map(samples, &elem(&1, 0)) == Telemetry.events()

    Enum.each(samples, fn {event, measurements, metadata} ->
      assert :ok = Telemetry.emit(event, measurements, metadata)

      assert_receive {:telemetry_event, ^event, emitted_measurements, emitted_metadata}
      assert emitted_measurements == Map.put(measurements, :count, 1)
      assert Map.keys(emitted_metadata) |> Enum.sort() == Map.keys(metadata) |> Enum.sort()
    end)
  end

  test "rejects undocumented or incomplete event data" do
    assert_raise ArgumentError, ~r/measurement keys/, fn ->
      Telemetry.emit(
        [:upnp, :ssdp, :datagram_dropped],
        %{},
        %{interface: {192, 0, 2, 10}, reason: :too_large}
      )
    end

    assert_raise ArgumentError, ~r/metadata keys/, fn ->
      Telemetry.emit(
        [:upnp, :ssdp, :interface_error],
        %{},
        %{interface: {192, 0, 2, 10}, reason: :error, response_body: "secret"}
      )
    end
  end

  test "oversized SSDP datagrams include count and byte measurements" do
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
    datagram = String.duplicate("x", 65_508)
    send(interface, {:udp, socket, {192, 0, 2, 1}, 1900, datagram})

    assert_receive {:telemetry_event, [:upnp, :ssdp, :datagram_dropped],
                    %{count: 1, bytes: 65_508}, %{interface: {192, 0, 2, 10}, reason: :too_large}}

    assert_receive {:activated, ^socket}
  end

  test "interface errors exclude exception payloads from metadata" do
    {:ok, clock} = start_supervised(Manual)

    {:ok, control_point} =
      start_supervised({ControlPoint, interfaces: [], clock: {Manual, clock}})

    secret = "adapter-secret-" <> String.duplicate("x", 1_024)
    reason = {:transport, RuntimeError.exception(secret)}
    send(control_point, {:interface_failed, {192, 0, 2, 10}, reason})

    assert_receive {:telemetry_event, [:upnp, :ssdp, :interface_error], %{count: 1}, metadata}

    assert metadata == %{interface: {192, 0, 2, 10}, reason: :transport_error}
    refute inspect(metadata) =~ secret
  end

  test "action telemetry excludes HTTP response bodies" do
    {:ok, clock} = start_supervised(Manual)
    secret = "response-secret-" <> String.duplicate("x", 1_024)
    body = action_response("GetStatusInfo", secret)

    options = %Options{
      action_timeout: 1_000,
      clock: {Manual, clock},
      http_adapter: {FakeHTTP, result: {:ok, %Response{status: 503, body: body}}}
    }

    service = %ServiceDescription{
      service_type: "urn:schemas-upnp-org:service:WANIPConnection:2",
      control_url: URI.parse("http://192.0.2.1/control")
    }

    assert {:error, {:http_status, 503, ^body}} =
             Action.invoke(service, "GetStatusInfo", [], options, [])

    assert_receive {:telemetry_event, [:upnp, :action, :invoke], %{count: 1}, metadata}

    assert metadata == %{
             action: "GetStatusInfo",
             outcome: {:error, {:http_status, 503}},
             service_type: "urn:schemas-upnp-org:service:WANIPConnection:2"
           }

    refute inspect(metadata) =~ secret
  end

  def forward_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp action_response(action, value) do
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <u:#{action}Response xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:2">
          <NewConnectionStatus>#{value}</NewConnectionStatus>
        </u:#{action}Response>
      </s:Body>
    </s:Envelope>
    """
  end
end
