defmodule UpnpExplorerWeb.ExplorerLiveTest do
  use UpnpExplorerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias UPnP.{
    ActionDescription,
    ActionResult,
    ArgumentDescription,
    DeviceDescription,
    SCPD,
    Service,
    ServiceDescription,
    StateVariable
  }

  alias UpnpExplorer.{DeviceView, Explorer, ServiceView}

  defmodule FakeControlPoint do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:get_scpd, _key, _url}, _from, test) do
      {:reply, {:ok, scpd()}, test}
    end

    def handle_call(
          {:invoke_action, _service, action_name, arguments, _options},
          _from,
          test
        ) do
      send(test, {:action_invoked, action_name, arguments})

      {:reply, {:ok, %ActionResult{out: %{"NewExternalIPAddress" => "203.0.113.42"}}}, test}
    end

    defp scpd do
      %SCPD{
        actions: [
          %ActionDescription{
            name: "GetExternalIPAddress",
            arguments: [
              %ArgumentDescription{
                name: "NewExternalIPAddress",
                direction: :out,
                is_return_value: true,
                related_state_variable: "ExternalIPAddress"
              }
            ]
          },
          %ActionDescription{
            name: "DeletePortMapping",
            arguments: [
              %ArgumentDescription{
                name: "NewExternalPort",
                direction: :in,
                related_state_variable: "ExternalPort"
              }
            ]
          }
        ],
        state_variables: [
          %StateVariable{
            name: "ExternalIPAddress",
            data_type: "string",
            sends_events: false
          },
          %StateVariable{
            name: "ExternalPort",
            data_type: "ui2",
            sends_events: false
          }
        ]
      }
    end
  end

  test "renders the network-disabled device observatory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#network-explorer")
    assert has_element?(view, "#device-roster")
    assert has_element?(view, "#device-count", "0")
    assert has_element?(view, "#probe-network[disabled]")
    assert has_element?(view, "nav a[aria-current=page]", "Devices")
    assert has_element?(view, "[data-phx-theme=system]")
  end

  test "switches and pauses the bounded activity journal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#activity-page")
    assert has_element?(view, "#activity-mode-changes.bg-\\[var\\(--accent\\)\\]")

    view
    |> element("#activity-mode-wire")
    |> render_click()

    assert has_element?(view, "#activity-mode-wire.bg-\\[var\\(--accent\\)\\]")

    view
    |> element("#activity-pause")
    |> render_click()

    assert has_element?(view, "#activity-pause", "Resume")
  end

  test "shows an actionable gateway error when networking is disabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gateway")

    render_async(view)

    assert has_element?(view, "#gateway-error", "Gateway discovery failed")
    assert has_element?(view, "#refresh-gateway")
    assert has_element?(view, "nav a[aria-current=page]", "Gateway")
  end

  test "queries the external address from a compatible service", %{conn: conn} do
    {device, service} = install_gateway_service()
    {:ok, view, _html} = live(conn, ~p"/devices/#{device.id}")

    view
    |> element("##{service.id}")
    |> render_click()

    render_async(view)

    assert has_element?(view, "#invoke-external-address", "Query current address")
    assert has_element?(view, "#service-actions", "DeletePortMapping")
    assert has_element?(view, "#service-actions", "does not invoke this action")

    render_click(view, "invoke-read-only-action", %{"name" => "DeletePortMapping"})

    assert has_element?(view, "#flash-error", "read-only query is not available")
    refute_received {:action_invoked, "DeletePortMapping", _arguments}

    view
    |> element("#invoke-external-address")
    |> render_click()

    render_async(view)

    assert_receive {:action_invoked, "GetExternalIPAddress", []}
    assert has_element?(view, "#external-address-result", "203.0.113.42")
  end

  defp install_gateway_service do
    control_point = start_supervised!({FakeControlPoint, self()})

    description = %ServiceDescription{
      service_type: "urn:schemas-upnp-org:service:WANIPConnection:1",
      service_id: "urn:upnp-org:serviceId:WANIPConn1",
      scpd_url: URI.parse("http://192.168.1.1/scpd.xml"),
      control_url: URI.parse("http://192.168.1.1/control")
    }

    service = Service.new(control_point, description, :live_view_test, {172, 17, 0, 1})

    summary =
      ServiceView.from_service(service, %DeviceDescription{
        friendly_name: "Dream Machine",
        udn: "uuid:dream-machine",
        device_type: "urn:schemas-upnp-org:device:WANConnectionDevice:1"
      })

    device = %DeviceView{
      id: "device-dream-machine",
      identity: "uuid:dream-machine",
      name: "Dream Machine",
      location: "http://192.168.1.1/root.xml",
      status: :online,
      host: "192.168.1.1",
      manufacturer: "Ubiquiti",
      model: "UDM",
      device_type: "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
      device_kind: "Internet gateway",
      udn: "uuid:dream-machine",
      local_address: "172.17.0.1",
      search_text: "dream machine ubiquiti udm internet connection",
      services: [summary],
      nodes: [],
      capabilities: [summary.name],
      service_count: 1,
      embedded_count: 0
    }

    original_state = :sys.get_state(Explorer)

    :sys.replace_state(Explorer, fn state ->
      entry = %{
        device: nil,
        described: nil,
        generation: nil,
        view: device,
        services: %{summary.id => service}
      }

      %{state | devices: %{device.id => entry}}
    end)

    on_exit(fn ->
      if explorer = Process.whereis(Explorer) do
        :sys.replace_state(explorer, fn _state -> original_state end)
      end
    end)

    {device, summary}
  end
end
