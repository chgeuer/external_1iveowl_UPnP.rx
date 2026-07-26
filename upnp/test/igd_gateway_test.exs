defmodule UPnP.IGDGatewayTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.IGD.{Gateway, Lease, LeaseEvent, Status}
  alias UPnP.{ControlPoint, Device, Service}
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.SSDP.Envelope

  defmodule FakeHTTP do
    @behaviour UPnP.HTTP

    @impl true
    def request(%Request{} = request, options) do
      test = Keyword.fetch!(options, :test)
      request_ref = make_ref()
      send(test, {:http_request, self(), request_ref, request})

      receive do
        {:http_response, ^request_ref, result} -> result
      end
    end
  end

  setup do
    {:ok, clock} = start_supervised(Manual)

    {:ok, control_point} =
      start_supervised(
        {ControlPoint,
         interfaces: [],
         clock: {Manual, clock},
         http_adapter: {FakeHTTP, test: self()},
         description_timeout: 1_000,
         action_timeout: 1_000}
      )

    gateway = resolve_gateway(control_point)
    cache_scpd(gateway)
    %{clock: clock, control_point: control_point, gateway: gateway}
  end

  test "routes the local address toward control instead of trusting the SSDP socket", %{
    gateway: gateway
  } do
    assert gateway.wan_service.description.service_type == service_type()
    assert gateway.device.device.local_address == {172, 19, 0, 1}
    assert gateway.local_address == {127, 0, 0, 1}

    external = Task.async(fn -> Gateway.external_address(gateway) end)
    {worker, request_ref, request} = next_action("GetExternalIPAddress")
    assert to_string(request.url) == "http://127.0.0.1/control/ip2"

    respond_action(worker, request_ref, "GetExternalIPAddress", [
      {"NewExternalIPAddress", "203.0.113.17"}
    ])

    assert {:ok, {203, 0, 113, 17}} = Task.await(external)

    status = Task.async(fn -> Gateway.status(gateway) end)
    {worker, request_ref, _request} = next_action("GetStatusInfo")

    respond_action(worker, request_ref, "GetStatusInfo", [
      {"NewConnectionStatus", "Connected"},
      {"NewLastConnectionError", "ERROR_NONE"},
      {"NewUptime", "7200"}
    ])

    assert {:ok,
            %Status{
              status: "Connected",
              last_error: "ERROR_NONE",
              uptime: 7_200
            } = value} = Task.await(status)

    assert Status.connected?(value)
  end

  test "gateway discovery resolves a matching device already in the roster", %{
    control_point: control_point
  } do
    ControlPoint.inject(control_point, %Envelope{
      kind: :alive,
      location: device().location,
      usn: device().usn,
      boot_id: device().boot_id,
      config_id: device().config_id,
      local_address: device().local_address,
      notification_type: "upnp:rootdevice",
      max_age: 60
    })

    assert [_device] = ControlPoint.roster(control_point)
    assert {:ok, %Gateway{} = gateway} = UPnP.IGD.discover_gateway(control_point)
    assert gateway.wan_service.description.service_type == service_type()
    refute_receive {:http_request, _, _, _}
  end

  test "adds a strictly ordered mapping and graceful close deletes it", %{gateway: gateway} do
    owner = self()

    adding =
      Task.async(fn ->
        Gateway.add_port_mapping(gateway, 18_080, 18_081, :tcp,
          description: "test map",
          lease_duration: 0,
          owner: owner
        )
      end)

    {worker, request_ref, request} = next_action("AddPortMapping")

    assert request.body =~
             "<NewRemoteHost></NewRemoteHost><NewExternalPort>18080</NewExternalPort>"

    assert request.body =~ "<NewInternalClient>127.0.0.1</NewInternalClient>"
    assert request.body =~ "<NewLeaseDuration>0</NewLeaseDuration>"
    respond_action(worker, request_ref, "AddPortMapping")

    assert {:ok, lease} = Task.await(adding)
    assert lease.mapping.internal_client == "127.0.0.1"

    closing = Task.async(fn -> Lease.close(lease) end)
    {worker, request_ref, request} = next_action("DeletePortMapping")
    assert request.body =~ "<NewExternalPort>18080</NewExternalPort>"
    respond_action(worker, request_ref, "DeletePortMapping")
    assert :ok = Task.await(closing)
  end

  test "abandon and owner loss never send a network delete", %{gateway: gateway} do
    owner = self()

    adding =
      Task.async(fn ->
        Gateway.add_port_mapping(gateway, 18_082, 18_082, :udp,
          lease_duration: 60,
          owner: owner
        )
      end)

    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert {:ok, lease} = Task.await(adding)
    monitor = Process.monitor(lease.server)
    assert :ok = Lease.abandon(lease)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    refute_receive {:http_request, _, _, %Request{method: "POST"}}

    owner_bound =
      Task.async(fn ->
        Gateway.add_port_mapping(gateway, 18_083, 18_083, :tcp, lease_duration: 60)
      end)

    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert {:ok, owner_bound_lease} = Task.await(owner_bound)
    monitor = Process.monitor(owner_bound_lease.server)
    assert_receive {:DOWN, ^monitor, :process, _, reason}
    assert reason in [:normal, :noproc]
    refute_receive {:http_request, _, _, %Request{method: "POST"}}
  end

  test "AddAnyPortMapping exposes the granted external port", %{gateway: gateway} do
    owner = self()

    adding =
      Task.async(fn ->
        Gateway.add_any_port_mapping(gateway, 18_080, 18_080, :tcp,
          lease_duration: 0,
          owner: owner
        )
      end)

    {worker, request_ref, _request} = next_action("AddAnyPortMapping")
    respond_action(worker, request_ref, "AddAnyPortMapping", [{"NewReservedPort", "18099"}])

    assert {:ok, lease} = Task.await(adding)
    assert lease.mapping.external_port == 18_099

    closing = Task.async(fn -> Lease.close(lease) end)
    {worker, request_ref, _request} = next_action("DeletePortMapping")
    respond_action(worker, request_ref, "DeletePortMapping")
    assert :ok = Task.await(closing)
  end

  test "lease renewal and close preserve validate false for incomplete SCPDs", %{
    clock: clock,
    gateway: gateway
  } do
    owner = self()
    gateway = put_in(gateway.wan_service.cache_scope, {:incomplete, make_ref()})

    adding =
      Task.async(fn ->
        Gateway.add_port_mapping(gateway, 18_100, 18_100, :tcp,
          lease_duration: 2,
          owner: owner,
          validate: false
        )
      end)

    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert {:ok, lease} = Task.await(adding)
    assert {:ok, subscription} = Lease.subscribe(lease)

    :ok = Manual.advance(clock, 1_000)
    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert_receive {:upnp, ref, %LeaseEvent{kind: :renewed}}
    assert ref == subscription.ref

    closing = Task.async(fn -> Lease.close(lease) end)
    {worker, request_ref, _request} = next_action("DeletePortMapping")
    respond_fault(worker, request_ref, 714, "NoSuchEntryInArray")
    assert :ok = Task.await(closing)
    refute_receive {:http_request, _, _, %Request{method: "GET"}}
  end

  test "gets and enumerates mappings until the gateway reports exhaustion", %{gateway: gateway} do
    specific = Task.async(fn -> Gateway.get_port_mapping(gateway, 8_080, :tcp) end)
    {worker, request_ref, _request} = next_action("GetSpecificPortMappingEntry")

    respond_action(worker, request_ref, "GetSpecificPortMappingEntry", [
      {"NewInternalPort", "9090"},
      {"NewInternalClient", "192.168.1.50"},
      {"NewEnabled", "1"},
      {"NewPortMappingDescription", "existing"},
      {"NewLeaseDuration", "600"}
    ])

    assert {:ok, mapping} = Task.await(specific)
    assert mapping.internal_port == 9_090
    assert mapping.lease_duration == 600

    listing = Task.async(fn -> Gateway.list_port_mappings(gateway) end)

    Enum.each(0..1, fn index ->
      {worker, request_ref, request} = next_action("GetGenericPortMappingEntry")
      assert request.body =~ "<NewPortMappingIndex>#{index}</NewPortMappingIndex>"

      respond_action(worker, request_ref, "GetGenericPortMappingEntry", [
        {"NewRemoteHost", ""},
        {"NewExternalPort", Integer.to_string(8_001 + index)},
        {"NewProtocol", if(index == 0, do: "TCP", else: "udp")},
        {"NewInternalPort", Integer.to_string(9_001 + index)},
        {"NewInternalClient", "192.168.1.5#{index + 1}"},
        {"NewEnabled", "true"},
        {"NewPortMappingDescription", "entry #{index + 1}"},
        {"NewLeaseDuration", "3600"}
      ])
    end)

    {worker, request_ref, _request} = next_action("GetGenericPortMappingEntry")
    respond_fault(worker, request_ref, 713, "SpecifiedArrayIndexInvalid")

    assert {:ok, [first, second]} = Task.await(listing)
    assert first.external_port == 8_001
    assert first.protocol == :tcp
    assert second.protocol == :udp
  end

  test "finite leases renew, expose failures as data, expire, and recover", %{
    clock: clock,
    gateway: gateway
  } do
    owner = self()

    adding =
      Task.async(fn ->
        Gateway.add_port_mapping(gateway, 18_084, 18_084, :tcp,
          lease_duration: 100,
          owner: owner
        )
      end)

    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert {:ok, lease} = Task.await(adding)
    assert {:ok, subscription} = Lease.subscribe(lease)

    :ok = Manual.advance(clock, 50_000)
    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert_receive {:upnp, ref, %LeaseEvent{kind: :renewed}}
    assert ref == subscription.ref

    Enum.each(1..3, fn failure ->
      :ok = Manual.advance(clock, 50_000)
      {worker, request_ref, _request} = next_action("AddPortMapping")
      respond_fault(worker, request_ref, 501, "ActionFailed")
      assert_receive {:upnp, ^ref, %LeaseEvent{kind: :renewal_failed}}

      if failure < 3 do
        refute_receive {:upnp, ^ref, %LeaseEvent{kind: :expired}}
      end
    end)

    assert_receive {:upnp, ^ref, %LeaseEvent{kind: :expired}}

    :ok = Manual.advance(clock, 50_000)
    {worker, request_ref, _request} = next_action("AddPortMapping")
    respond_action(worker, request_ref, "AddPortMapping")
    assert_receive {:upnp, ^ref, %LeaseEvent{kind: :renewed}}

    closing = Task.async(fn -> Lease.close(lease) end)
    {worker, request_ref, _request} = next_action("DeletePortMapping")
    respond_action(worker, request_ref, "DeletePortMapping")
    assert :ok = Task.await(closing)
  end

  defp resolve_gateway(control_point) do
    task = Task.async(fn -> UPnP.IGD.from_device(control_point, device()) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, description_xml())
    assert {:ok, gateway} = Task.await(task)
    gateway
  end

  defp cache_scpd(gateway) do
    task = Task.async(fn -> Service.get_scpd(gateway.wan_service) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, scpd_xml())
    assert {:ok, _scpd} = Task.await(task)
  end

  defp next_action(expected) do
    assert_receive {:http_request, worker, request_ref, %Request{method: "POST"} = request}
    assert action_name(request) == expected
    {worker, request_ref, request}
  end

  defp respond_action(worker, request_ref, action, arguments \\ []) do
    children =
      Enum.map_join(arguments, fn {name, value} ->
        "<#{name}>#{value}</#{name}>"
      end)

    body = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body><u:#{action}Response xmlns:u="#{service_type()}">#{children}</u:#{action}Response></s:Body>
    </s:Envelope>
    """

    respond(worker, request_ref, 200, body)
  end

  defp respond_fault(worker, request_ref, code, description) do
    body = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body><s:Fault><detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>#{code}</errorCode><errorDescription>#{description}</errorDescription>
        </UPnPError>
      </detail></s:Fault></s:Body>
    </s:Envelope>
    """

    respond(worker, request_ref, 500, body)
  end

  defp respond(worker, request_ref, status, body) do
    send(
      worker,
      {:http_response, request_ref, {:ok, %Response{status: status, body: body}}}
    )
  end

  defp action_name(%Request{body: body}) do
    [_, action] = Regex.run(~r/<u:([A-Za-z0-9_.-]+)/, IO.iodata_to_binary(body))
    action
  end

  defp device do
    %Device{
      location: URI.parse("http://127.0.0.1/device.xml"),
      usn: "uuid:gateway::upnp:rootdevice",
      boot_id: 1,
      config_id: 9,
      local_address: {172, 19, 0, 1}
    }
  end

  defp description_xml do
    """
    <root configId="9"><device>
      <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:2</deviceType>
      <friendlyName>Gateway</friendlyName><UDN>uuid:gateway</UDN>
      <serviceList>
        <service>
          <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
          <serviceId>urn:upnp-org:serviceId:WANPPPConn1</serviceId>
          <SCPDURL>/ppp.xml</SCPDURL><controlURL>/control/ppp</controlURL>
        </service>
        <service>
          <serviceType>#{service_type()}</serviceType>
          <serviceId>urn:upnp-org:serviceId:WANIPConn2</serviceId>
          <SCPDURL>/ip2.xml</SCPDURL><controlURL>/control/ip2</controlURL>
        </service>
      </serviceList>
    </device></root>
    """
  end

  defp scpd_xml do
    actions = [
      {"GetExternalIPAddress", []},
      {"GetStatusInfo", []},
      {"AddPortMapping", add_argument_names()},
      {"AddAnyPortMapping", add_argument_names()},
      {"DeletePortMapping", ["NewRemoteHost", "NewExternalPort", "NewProtocol"]},
      {"GetSpecificPortMappingEntry", ["NewRemoteHost", "NewExternalPort", "NewProtocol"]},
      {"GetGenericPortMappingEntry", ["NewPortMappingIndex"]}
    ]

    encoded =
      Enum.map_join(actions, fn {name, arguments} ->
        argument_list =
          Enum.map_join(arguments, fn argument ->
            """
            <argument><name>#{argument}</name><direction>in</direction>
              <relatedStateVariable>#{argument}</relatedStateVariable></argument>
            """
          end)

        "<action><name>#{name}</name><argumentList>#{argument_list}</argumentList></action>"
      end)

    "<scpd><actionList>#{encoded}</actionList></scpd>"
  end

  defp add_argument_names do
    [
      "NewRemoteHost",
      "NewExternalPort",
      "NewProtocol",
      "NewInternalPort",
      "NewInternalClient",
      "NewEnabled",
      "NewPortMappingDescription",
      "NewLeaseDuration"
    ]
  end

  defp service_type, do: "urn:schemas-upnp-org:service:WANIPConnection:2"
end
