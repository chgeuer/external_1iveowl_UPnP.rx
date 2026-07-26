defmodule UpnpExplorer.ExplorerTest do
  use ExUnit.Case, async: true

  alias UPnP.{ActionResult, DeviceDescription, Service, ServiceDescription}

  alias UpnpExplorer.{
    Activity,
    DeviceView,
    Explorer,
    ServiceView,
    TestActionControlPoint
  }

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
end
