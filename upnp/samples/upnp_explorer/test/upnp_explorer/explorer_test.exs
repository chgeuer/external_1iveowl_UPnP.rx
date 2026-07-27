defmodule UpnpExplorer.ExplorerTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual

  alias UPnP.{
    ActionResult,
    ControlPoint,
    DeviceDescription,
    Service,
    ServiceDescription
  }

  alias UPnP.SSDP.Envelope

  alias UpnpExplorer.{
    Activity,
    DeviceView,
    Explorer,
    ServiceView,
    TestActionControlPoint
  }

  defmodule DescriptionHTTP do
    @behaviour UPnP.HTTP

    @impl true
    def request(_request, options) do
      {:ok, %UPnP.HTTP.Response{status: 200, body: Keyword.fetch!(options, :body)}}
    end
  end

  defmodule StaticNetwork do
    @behaviour UPnP.Network

    @impl true
    def local_address_for(_uri, address), do: {:ok, address}
  end

  test "network-disabled mode remains queryable without pretending discovery is active" do
    name = :"explorer-#{System.unique_integer([:positive])}"
    start_supervised!({Explorer, name: name, control_point: nil})

    assert %{
             devices: [],
             activities: [],
             status: %{
               network_available?: false,
               device_count: 0,
               pending_count: 0,
               runtime_error: :network_disabled
             }
           } = Explorer.snapshot(name)

    assert Explorer.list_devices("receiver", name) == []
    assert Explorer.list_activity(:all, name) == []
    assert Explorer.get_device("missing", name) == {:error, :not_found}
    assert Explorer.probe(name) == {:error, :network_unavailable}
  end

  test "records a mutation outcome after its caller disappears" do
    name = :"explorer-#{System.unique_integer([:positive])}"
    explorer = start_supervised!({Explorer, name: name, control_point: nil})
    control_point = start_supervised!({TestActionControlPoint, test: self(), mode: :controlled})
    {device, summary, service} = gateway_service(control_point)

    :sys.replace_state(explorer, fn state ->
      entry = %{
        device: nil,
        described: nil,
        generation: nil,
        view: device,
        services: %{summary.id => service}
      }

      %{state | devices: %{device.id => entry}}
    end)

    :ok = Explorer.subscribe()

    task_supervisor =
      start_supervised!(
        {Task.Supervisor, name: :"action-caller-#{System.unique_integer([:positive])}"}
      )

    caller =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Explorer.invoke_action(
          device.id,
          summary.id,
          "DeletePortMapping",
          %{"NewExternalPort" => "443", "NewProtocol" => "TCP"},
          server: name
        )
      end)

    assert_receive {:action_invoked, "DeletePortMapping",
                    [{"NewExternalPort", "443"}, {"NewProtocol", "TCP"}]}

    Task.shutdown(caller, :brutal_kill)
    TestActionControlPoint.reply(control_point, {:ok, %ActionResult{}})

    assert_receive {:explorer_activity_upserted,
                    %Activity{
                      kind: :action_succeeded,
                      title: "DeletePortMapping completed on Dream Machine"
                    }}

    assert Enum.any?(Explorer.list_activity(:changes, name), &(&1.kind == :action_succeeded))
  end

  test "groups root and embedded advertisements that share one device description" do
    {:ok, clock} = start_supervised(Manual)

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [],
         clock: {Manual, clock},
         http_adapter: {DescriptionHTTP, body: dream_machine_description()},
         network_adapter: {StaticNetwork, {192, 168, 1, 195}}},
        id: :grouped_location_control_point
      )

    name = :"explorer-#{System.unique_integer([:positive])}"
    explorer = start_supervised!({Explorer, name: name, control_point: control_point})
    :ok = Explorer.subscribe()

    usns = [
      "uuid:dream-wan-connection::urn:schemas-upnp-org:device:WANConnectionDevice:2",
      "uuid:dream-root::upnp:rootdevice",
      "uuid:dream-wan::urn:schemas-upnp-org:device:WANDevice:2"
    ]

    Enum.each(usns, fn usn ->
      :ok = ControlPoint.inject(control_point, dream_machine_alive(usn))

      assert_receive {:explorer_device_upserted,
                      %DeviceView{name: "UniFi Dream Machine", status: :online}}

      _state = :sys.get_state(explorer)
    end)

    assert [%DeviceView{} = device] = Explorer.list_devices("", name)
    assert device.udn == "uuid:dream-root"
    assert device.local_address == "192.168.1.195"
    device_id = device.id

    [first, second, last] = usns

    for usn <- [first, second] do
      :ok = ControlPoint.inject(control_point, %Envelope{kind: :byebye, usn: usn})
      assert_receive {:explorer_device_upserted, %DeviceView{id: ^device_id, status: :online}}

      assert [_device] = Explorer.list_devices("", name)
    end

    :ok = ControlPoint.inject(control_point, %Envelope{kind: :byebye, usn: last})
    assert_receive {:explorer_device_removed, ^device_id}
    assert Explorer.list_devices("", name) == []
  end

  defp gateway_service(control_point) do
    description = %ServiceDescription{
      service_type: "urn:schemas-upnp-org:service:WANIPConnection:1",
      service_id: "urn:upnp-org:serviceId:WANIPConn1",
      scpd_url: URI.parse("http://192.168.1.1/scpd.xml"),
      control_url: URI.parse("http://192.168.1.1/control")
    }

    service = Service.new(control_point, description, :explorer_test)

    summary =
      ServiceView.from_service(service, %DeviceDescription{
        friendly_name: "Dream Machine",
        udn: "uuid:dream-machine"
      })

    device = %DeviceView{
      id: "device-dream-machine",
      identity: "uuid:dream-machine",
      name: "Dream Machine",
      location: "http://192.168.1.1/root.xml",
      status: :online,
      services: [summary],
      nodes: [],
      capabilities: [summary.name],
      service_count: 1,
      embedded_count: 0,
      search_text: "dream machine"
    }

    {device, summary, service}
  end

  defp dream_machine_alive(usn) do
    %Envelope{
      kind: :alive,
      usn: usn,
      notification_type: usn |> String.split("::", parts: 2) |> List.last(),
      location: URI.parse("http://192.168.1.1:45105/rootDesc.xml"),
      boot_id: 1_785_057_201,
      config_id: 1_337,
      max_age: 1_800,
      local_address: {172, 20, 0, 1},
      remote_endpoint: {{192, 168, 1, 1}, 38_366}
    }
  end

  defp dream_machine_description do
    """
    <root xmlns="urn:schemas-upnp-org:device-1-0" configId="1337">
      <specVersion><major>2</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:2</deviceType>
        <friendlyName>UniFi Dream Machine</friendlyName>
        <manufacturer>Ubiquiti Inc.</manufacturer>
        <modelName>UDM Pro</modelName>
        <UDN>uuid:dream-root</UDN>
      </device>
    </root>
    """
  end
end
