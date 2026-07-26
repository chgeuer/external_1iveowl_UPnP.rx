defmodule UPnP.DescriptionControlTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
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

    %{clock: clock, control_point: control_point}
  end

  test "description fetches are single-flight and successful values are cached", %{
    control_point: control_point
  } do
    device = device(1)
    first = Task.async(fn -> ControlPoint.describe(control_point, device) end)

    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"} = request}
    assert to_string(request.url) == "http://192.0.2.1/device.xml"

    tag = make_ref()
    key = {URI.to_string(device.location), device.config_id, device.boot_id}

    send(
      control_point,
      {:"$gen_call", {self(), tag}, {:get_description, key, device.location}}
    )

    assert length(:sys.get_state(control_point).pending[{:description, key}]) == 2
    refute_receive {:http_request, _, _, _}

    respond(worker, request_ref, 200, description_xml())

    assert {:ok, described} = Task.await(first)
    assert described.description.friendly_name == "Test Gateway"
    assert_receive {^tag, {:ok, cached_description}}
    assert cached_description == described.description

    assert {:ok, cached} = ControlPoint.describe(control_point, device)
    assert cached.description == described.description
    refute_receive {:http_request, _, _, _}
  end

  test "service clients cache SCPD, order arguments, and parse SOAP results", %{
    control_point: control_point
  } do
    {:ok, described} = fetch_description(control_point, device(1))

    assert {:ok, service} =
             UPnP.DescribedDevice.service(
               described,
               "urn:upnp-org:serviceId:WANIPConn1"
             )

    invoke =
      Task.async(fn ->
        Service.invoke(service, "AddPortMapping", %{
          "NewProtocol" => "TCP",
          "NewExternalPort" => "8080"
        })
      end)

    assert_receive {:http_request, scpd_worker, scpd_ref, %Request{method: "GET"} = request}
    assert to_string(request.url) == "http://192.0.2.1/wanip.xml"
    respond(scpd_worker, scpd_ref, 200, scpd_xml())

    assert_receive {:http_request, soap_worker, soap_ref, %Request{method: "POST"} = request}
    assert to_string(request.url) == "http://192.0.2.1/control"

    assert header(request, "soapaction") ==
             ~s("urn:schemas-upnp-org:service:WANIPConnection:2#AddPortMapping")

    assert request.body =~
             "<NewExternalPort>8080</NewExternalPort><NewProtocol>TCP</NewProtocol>"

    respond(soap_worker, soap_ref, 200, action_response("AddPortMapping", []))
    assert {:ok, %UPnP.ActionResult{out: %{}}} = Task.await(invoke)

    second = Task.async(fn -> Service.invoke(service, "GetExternalIPAddress") end)

    assert_receive {:http_request, worker, response_ref, %Request{method: "POST"}}

    respond(
      worker,
      response_ref,
      200,
      action_response("GetExternalIPAddress", [
        {"NewExternalIPAddress", "203.0.113.8"}
      ])
    )

    assert {:ok, result} = Task.await(second)
    assert UPnP.ActionResult.get(result, "newexternalipaddress") == "203.0.113.8"
    refute_receive {:http_request, _, _, %Request{method: "GET"}}
  end

  test "SOAP faults are protocol data and invalid calls never reach the network", %{
    control_point: control_point
  } do
    {:ok, described} = fetch_description(control_point, device(1))
    {:ok, service} = UPnP.DescribedDevice.service(described, service_type())

    scpd = Task.async(fn -> Service.get_scpd(service) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, scpd_xml())
    assert {:ok, _scpd} = Task.await(scpd)

    assert {:error, {:missing_argument, "NewExternalPort"}} =
             Service.invoke(service, "AddPortMapping", [{"NewProtocol", "TCP"}])

    assert {:error, {:unknown_action, "NoSuchAction"}} =
             Service.invoke(service, "NoSuchAction")

    refute_receive {:http_request, _, _, _}

    invoke =
      Task.async(fn ->
        Service.invoke(service, "AddPortMapping", [
          {"NewExternalPort", "8080"},
          {"NewProtocol", "TCP"}
        ])
      end)

    assert_receive {:http_request, fault_worker, fault_ref, %Request{method: "POST"}}
    respond(fault_worker, fault_ref, 500, fault_response(718, "ConflictInMappingEntry"))

    assert {:error,
            {:upnp_error, %UPnP.UpnpError{code: 718, description: "ConflictInMappingEntry"}}} =
             Task.await(invoke)
  end

  test "a clock deadline terminates a stalled fetch and failures are not cached", %{
    clock: clock,
    control_point: control_point
  } do
    device = device(1)
    first = Task.async(fn -> ControlPoint.describe(control_point, device) end)

    assert_receive {:http_request, _worker, _request_ref, %Request{method: "GET"}}
    _clock_state = :sys.get_state(clock)
    :ok = Manual.advance(clock, 1_000)
    assert {:error, :timeout} = Task.await(first)

    retry = Task.async(fn -> ControlPoint.describe(control_point, device) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, description_xml())
    assert {:ok, _described} = Task.await(retry)
  end

  test "a new boot ID does not reuse the old description", %{control_point: control_point} do
    assert {:ok, _first} = fetch_description(control_point, device(1))

    second = Task.async(fn -> ControlPoint.describe(control_point, device(2)) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, description_xml())
    assert {:ok, _second} = Task.await(second)
  end

  test "a roster reboot prunes description and SCPD cache generations", %{
    control_point: control_point
  } do
    {:ok, described} = fetch_description(control_point, device(1))
    {:ok, service} = UPnP.DescribedDevice.service(described, service_type())

    scpd = Task.async(fn -> Service.get_scpd(service) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, scpd_xml())
    assert {:ok, _value} = Task.await(scpd)

    assert map_size(:sys.get_state(control_point).description_cache) == 1
    assert map_size(:sys.get_state(control_point).scpd_cache) == 1

    ControlPoint.inject(control_point, alive(1))
    assert [_device] = ControlPoint.roster(control_point)
    ControlPoint.inject(control_point, alive(2))
    assert [_device] = ControlPoint.roster(control_point)

    state = :sys.get_state(control_point)
    assert state.description_cache == %{}
    assert state.scpd_cache == %{}
  end

  defp fetch_description(control_point, device) do
    task = Task.async(fn -> ControlPoint.describe(control_point, device) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, description_xml())
    Task.await(task)
  end

  defp respond(worker, request_ref, status, body, headers \\ []) do
    send(
      worker,
      {:http_response, request_ref,
       {:ok, %Response{status: status, headers: headers, body: body}}}
    )
  end

  defp header(request, name) do
    name = String.downcase(name)

    Enum.find_value(request.headers, fn {header_name, value} ->
      if String.downcase(header_name) == name, do: value
    end)
  end

  defp device(boot_id) do
    %Device{
      location: URI.parse("http://192.0.2.1/device.xml"),
      usn: "uuid:gateway::upnp:rootdevice",
      boot_id: boot_id,
      config_id: 7
    }
  end

  defp alive(boot_id) do
    %Envelope{
      kind: :alive,
      location: device(boot_id).location,
      usn: device(boot_id).usn,
      boot_id: boot_id,
      config_id: device(boot_id).config_id,
      notification_type: "upnp:rootdevice",
      max_age: 60
    }
  end

  defp description_xml do
    """
    <root configId="7">
      <device>
        <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:2</deviceType>
        <friendlyName>Test Gateway</friendlyName>
        <UDN>uuid:gateway</UDN>
        <serviceList>
          <service>
            <serviceType>#{service_type()}</serviceType>
            <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
            <SCPDURL>/wanip.xml</SCPDURL>
            <controlURL>/control</controlURL>
            <eventSubURL>/events</eventSubURL>
          </service>
        </serviceList>
      </device>
    </root>
    """
  end

  defp scpd_xml do
    """
    <scpd>
      <actionList>
        <action>
          <name>AddPortMapping</name>
          <argumentList>
            <argument>
              <name>NewExternalPort</name><direction>in</direction>
              <relatedStateVariable>ExternalPort</relatedStateVariable>
            </argument>
            <argument>
              <name>NewProtocol</name><direction>in</direction>
              <relatedStateVariable>PortMappingProtocol</relatedStateVariable>
            </argument>
          </argumentList>
        </action>
        <action><name>GetExternalIPAddress</name></action>
      </actionList>
    </scpd>
    """
  end

  defp action_response(action, arguments) do
    children =
      Enum.map_join(arguments, fn {name, value} ->
        "<#{name}>#{value}</#{name}>"
      end)

    """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <u:#{action}Response xmlns:u="#{service_type()}">#{children}</u:#{action}Response>
      </s:Body>
    </s:Envelope>
    """
  end

  defp fault_response(code, description) do
    """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body><s:Fault><detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>#{code}</errorCode>
          <errorDescription>#{description}</errorDescription>
        </UPnPError>
      </detail></s:Fault></s:Body>
    </s:Envelope>
    """
  end

  defp service_type, do: "urn:schemas-upnp-org:service:WANIPConnection:2"
end
