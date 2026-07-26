defmodule UPnP.DescriptionControlTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.{ControlPoint, Device, Service}
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.SSDP.Envelope

  @async_timeout 1_000

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
    task_supervisor = start_supervised!(Task.Supervisor)

    {:ok, control_point} =
      start_supervised(
        {ControlPoint,
         interfaces: [],
         clock: {Manual, clock},
         http_adapter: {FakeHTTP, test: self()},
         description_timeout: 1_000,
         action_timeout: 1_000}
      )

    %{clock: clock, control_point: control_point, task_supervisor: task_supervisor}
  end

  test "concurrent description fetches are single-flight and successful values are cached", %{
    control_point: control_point,
    task_supervisor: task_supervisor
  } do
    device = device(1)

    calls =
      start_concurrently(task_supervisor, [
        fn -> ControlPoint.describe(control_point, device) end,
        fn -> ControlPoint.describe(control_point, device) end
      ])

    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"} = request}
    assert to_string(request.url) == "http://192.0.2.1/device.xml"
    respond(worker, request_ref, 200, description_xml())

    assert [first_result, second_result] =
             Enum.map(calls, &Task.await(&1, @async_timeout))

    assert {:ok, first} = first_result
    assert {:ok, second} = second_result
    assert first == second
    assert first.description.friendly_name == "Test Gateway"
    refute_received {:http_request, _, _, _}

    assert {:ok, cached} = ControlPoint.describe(control_point, device)
    assert cached == first
    refute_received {:http_request, _, _, _}
  end

  test "service clients cache SCPD, order arguments, and parse SOAP results", %{
    control_point: control_point,
    task_supervisor: task_supervisor
  } do
    {:ok, described} = fetch_description(control_point, device(1), task_supervisor)

    assert {:ok, service} =
             UPnP.DescribedDevice.service(
               described,
               "urn:upnp-org:serviceId:WANIPConn1"
             )

    invoke =
      async(task_supervisor, fn ->
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
    assert {:ok, %UPnP.ActionResult{out: %{}}} = Task.await(invoke, @async_timeout)

    assert {:ok, cached_scpd} = Service.get_scpd(service)
    assert Enum.any?(cached_scpd.actions, &(&1.name == "AddPortMapping"))
    refute_received {:http_request, _, _, %Request{method: "GET"}}

    second = async(task_supervisor, fn -> Service.invoke(service, "GetExternalIPAddress") end)

    assert_receive {:http_request, worker, response_ref, %Request{method: "POST"}}

    respond(
      worker,
      response_ref,
      200,
      action_response("GetExternalIPAddress", [
        {"NewExternalIPAddress", "203.0.113.8"}
      ])
    )

    assert {:ok, result} = Task.await(second, @async_timeout)
    assert UPnP.ActionResult.get(result, "newexternalipaddress") == "203.0.113.8"
    refute_received {:http_request, _, _, %Request{method: "GET"}}
  end

  test "SOAP faults are protocol data and invalid calls never reach the network", %{
    control_point: control_point,
    task_supervisor: task_supervisor
  } do
    {:ok, described} = fetch_description(control_point, device(1), task_supervisor)
    {:ok, service} = UPnP.DescribedDevice.service(described, service_type())

    scpd = async(task_supervisor, fn -> Service.get_scpd(service) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, scpd_xml())
    assert {:ok, _scpd} = Task.await(scpd, @async_timeout)

    assert {:error, {:missing_argument, "NewExternalPort"}} =
             Service.invoke(service, "AddPortMapping", [{"NewProtocol", "TCP"}])

    assert {:error, {:unknown_action, "NoSuchAction"}} =
             Service.invoke(service, "NoSuchAction")

    assert Service.invoke(service, "AddPortMapping", :invalid) ==
             {:error, :invalid_arguments}

    assert Service.invoke(service, "AddPortMapping", [{"NewExternalPort", "8080"}, :invalid]) ==
             {:error, :invalid_arguments}

    assert Service.invoke(service, "AddPortMapping", [
             {"NewExternalPort", "8080"},
             {"newexternalport", "8081"},
             {"NewProtocol", "TCP"}
           ]) == {:error, {:duplicate_argument, "newexternalport"}}

    assert Service.invoke(service, "AddPortMapping", [
             {"NewExternalPort", "8080"},
             {"NewProtocol", "TCP"},
             {"Unknown", "value"}
           ]) == {:error, {:unknown_argument, "Unknown"}}

    refute_received {:http_request, _, _, _}

    invoke =
      async(task_supervisor, fn ->
        Service.invoke(service, "AddPortMapping", [
          {"NewExternalPort", "8080"},
          {"NewProtocol", "TCP"}
        ])
      end)

    assert_receive {:http_request, fault_worker, fault_ref, %Request{method: "POST"}}
    respond(fault_worker, fault_ref, 500, fault_response(718, "ConflictInMappingEntry"))

    assert {:error,
            {:upnp_error, %UPnP.UpnpError{code: 718, description: "ConflictInMappingEntry"}}} =
             Task.await(invoke, @async_timeout)
  end

  test "description timeouts and parse failures are not cached", %{
    clock: clock,
    control_point: control_point,
    task_supervisor: task_supervisor
  } do
    timeout_device = device(1)
    first = async(task_supervisor, fn -> ControlPoint.describe(control_point, timeout_device) end)

    assert_receive {:http_request, _worker, _request_ref, %Request{method: "GET"}}
    :ok = Manual.advance(clock, 1_000)
    assert {:error, :timeout} = Task.await(first, @async_timeout)

    assert {:ok, timeout_retry} =
             fetch_description(control_point, timeout_device, task_supervisor)

    assert {:ok, ^timeout_retry} = ControlPoint.describe(control_point, timeout_device)
    refute_received {:http_request, _, _, _}

    parse_device = device(2)
    failed = async(task_supervisor, fn -> ControlPoint.describe(control_point, parse_device) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, "<root>")

    assert {:error, %UPnP.ParseError{source: :device_description}} =
             Task.await(failed, @async_timeout)

    assert {:ok, parse_retry} =
             fetch_description(control_point, parse_device, task_supervisor)

    assert {:ok, ^parse_retry} = ControlPoint.describe(control_point, parse_device)
    refute_received {:http_request, _, _, _}
  end

  test "SCPD timeouts and parse failures are not cached", %{
    clock: clock,
    control_point: control_point,
    task_supervisor: task_supervisor
  } do
    {:ok, timeout_description} =
      fetch_description(control_point, device(1), task_supervisor)

    {:ok, timeout_service} =
      UPnP.DescribedDevice.service(timeout_description, service_type())

    first = async(task_supervisor, fn -> Service.get_scpd(timeout_service) end)
    assert_receive {:http_request, _worker, _request_ref, %Request{method: "GET"}}
    :ok = Manual.advance(clock, 1_000)
    assert {:error, :timeout} = Task.await(first, @async_timeout)

    assert {:ok, timeout_retry} = fetch_scpd(timeout_service, task_supervisor)
    assert {:ok, ^timeout_retry} = Service.get_scpd(timeout_service)
    refute_received {:http_request, _, _, _}

    {:ok, parse_description} =
      fetch_description(control_point, device(2), task_supervisor)

    {:ok, parse_service} =
      UPnP.DescribedDevice.service(parse_description, service_type())

    failed = async(task_supervisor, fn -> Service.get_scpd(parse_service) end)
    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"}}
    respond(worker, request_ref, 200, "<scpd>")

    assert {:error, %UPnP.ParseError{source: :scpd}} =
             Task.await(failed, @async_timeout)

    assert {:ok, parse_retry} = fetch_scpd(parse_service, task_supervisor)
    assert {:ok, ^parse_retry} = Service.get_scpd(parse_service)
    refute_received {:http_request, _, _, _}
  end

  test "boot and config generation changes refetch descriptions and SCPDs", %{
    control_point: control_point,
    task_supervisor: task_supervisor
  } do
    Enum.each([{1, 7}, {2, 7}, {2, 8}], fn {boot_id, config_id} ->
      ControlPoint.inject(control_point, alive(boot_id, config_id))

      assert [
               %Device{boot_id: ^boot_id, config_id: ^config_id} = current_device
             ] = ControlPoint.roster(control_point)

      assert {:ok, described} =
               fetch_description(
                 control_point,
                 current_device,
                 task_supervisor,
                 description_xml(config_id)
               )

      assert {:ok, service} =
               UPnP.DescribedDevice.service(described, service_type())

      assert {:ok, scpd} = fetch_scpd(service, task_supervisor)

      assert {:ok, ^described} = ControlPoint.describe(control_point, current_device)
      assert {:ok, ^scpd} = Service.get_scpd(service)
      refute_received {:http_request, _, _, _}
    end)
  end

  defp start_concurrently(task_supervisor, functions) do
    parent = self()
    gate = make_ref()

    tasks =
      Enum.map(functions, fn function ->
        async(task_supervisor, fn ->
          send(parent, {:concurrent_call_ready, gate, self()})

          receive do
            {:start_concurrent_call, ^gate} -> function.()
          after
            @async_timeout -> exit(:concurrent_call_not_started)
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      task_pid = task.pid
      assert_receive {:concurrent_call_ready, ^gate, ^task_pid}, @async_timeout
    end)

    Enum.each(tasks, &send(&1.pid, {:start_concurrent_call, gate}))
    tasks
  end

  defp async(task_supervisor, function) do
    Task.Supervisor.async_nolink(task_supervisor, function)
  end

  defp fetch_description(control_point, device, task_supervisor, body \\ nil) do
    task = async(task_supervisor, fn -> ControlPoint.describe(control_point, device) end)

    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"} = request},
                   @async_timeout

    assert request.url == device.location
    respond(worker, request_ref, 200, body || description_xml(device.config_id || 7))
    Task.await(task, @async_timeout)
  end

  defp fetch_scpd(service, task_supervisor) do
    task = async(task_supervisor, fn -> Service.get_scpd(service) end)

    assert_receive {:http_request, worker, request_ref, %Request{method: "GET"} = request},
                   @async_timeout

    assert request.url == service.description.scpd_url
    respond(worker, request_ref, 200, scpd_xml())
    Task.await(task, @async_timeout)
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

  defp device(boot_id, config_id \\ 7) do
    %Device{
      location: URI.parse("http://192.0.2.1/device.xml"),
      usn: "uuid:gateway::upnp:rootdevice",
      boot_id: boot_id,
      config_id: config_id
    }
  end

  defp alive(boot_id, config_id) do
    device = device(boot_id, config_id)

    %Envelope{
      kind: :alive,
      location: device.location,
      usn: device.usn,
      boot_id: boot_id,
      config_id: config_id,
      notification_type: "upnp:rootdevice",
      max_age: 60
    }
  end

  defp description_xml(config_id \\ 7) do
    """
    <root configId="#{config_id}">
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
