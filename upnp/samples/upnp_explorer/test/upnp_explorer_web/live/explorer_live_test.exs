defmodule UpnpExplorerWeb.ExplorerLiveTest do
  use UpnpExplorerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias UPnP.{DeviceDescription, Service, ServiceDescription}

  alias UpnpExplorer.{DeviceView, Explorer, ServiceView, TestActionControlPoint}

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

  test "generates and runs a zero-input query", %{conn: conn} do
    {device, service} = install_gateway_service()
    {:ok, view, _html} = live(conn, ~p"/devices/#{device.id}")

    view
    |> element("##{service.id}")
    |> render_click()

    render_async(view)

    assert has_element?(
             view,
             "form[phx-value-action='GetExternalIPAddress'] button[type=submit]",
             "Run query"
           )

    assert has_element?(view, "#service-actions", "DeletePortMapping")

    view
    |> form("form[phx-value-action='GetExternalIPAddress']", %{})
    |> render_submit()

    render_async(view)

    assert_receive {:action_invoked, "GetExternalIPAddress", []}
    assert has_element?(view, "[id^='result-action-']", "NewExternalIPAddress")
    assert has_element?(view, "[id^='result-action-']", "203.0.113.42")
  end

  test "generates inputs and confirms a state-changing action", %{conn: conn} do
    {device, service} = install_gateway_service()
    {:ok, view, _html} = live(conn, ~p"/devices/#{device.id}")

    view
    |> element("##{service.id}")
    |> render_click()

    render_async(view)

    form_selector = "form[phx-value-action='DeletePortMapping']"

    assert has_element?(
             view,
             "#{form_selector} input[name='arguments[NewExternalPort]'][min='1'][max='65535']"
           )

    assert has_element?(
             view,
             "#{form_selector} select[name='arguments[NewProtocol]'] option[value='TCP']"
           )

    view
    |> form(form_selector, %{
      "arguments" => %{"NewExternalPort" => "443", "NewProtocol" => "TCP"}
    })
    |> render_submit()

    assert has_element?(view, "[id^='confirm-action-']", "Confirm DeletePortMapping")
    refute_received {:action_invoked, "DeletePortMapping", _arguments}

    view
    |> element("button[phx-click='confirm-action'][phx-value-action='DeletePortMapping']")
    |> render_click()

    render_async(view)

    assert_receive {:action_invoked, "DeletePortMapping",
                    [{"NewExternalPort", "443"}, {"NewProtocol", "TCP"}]}

    assert has_element?(view, "[id^='result-action-']", "returned no output arguments")

    assert Enum.any?(
             Explorer.list_activity(:changes),
             &(&1.kind == :action_succeeded and &1.title =~ "DeletePortMapping")
           )
  end

  test "requires confirmation for disruptive zero-input actions", %{conn: conn} do
    {device, service} = install_gateway_service()
    {:ok, view, _html} = live(conn, ~p"/devices/#{device.id}")

    view
    |> element("##{service.id}")
    |> render_click()

    render_async(view)

    view
    |> form("form[phx-value-action='ForceTermination']", %{})
    |> render_submit()

    assert has_element?(view, "[id^='confirm-action-']", "Internet or device access")
    assert has_element?(view, "button[phx-click='confirm-action']", "Disconnect WAN")
    refute_received {:action_invoked, "ForceTermination", []}
  end

  test "keeps device action failures beside the action", %{conn: conn} do
    {device, service} = install_gateway_service()
    {:ok, view, _html} = live(conn, ~p"/devices/#{device.id}")

    view
    |> element("##{service.id}")
    |> render_click()

    render_async(view)

    view
    |> form("form[phx-value-action='RequestConnection']", %{})
    |> render_submit()

    view
    |> element("button[phx-click='confirm-action'][phx-value-action='RequestConnection']")
    |> render_click()

    render_async(view)

    assert_receive {:action_invoked, "RequestConnection", []}
    assert has_element?(view, "[id^='error-action-']", "Action failed")
    assert has_element?(view, "[id^='error-action-']", "upnp_error")
  end

  test "rejects forged actions and concurrent preparations", %{conn: conn} do
    {device, service} = install_gateway_service()
    {:ok, view, _html} = live(conn, ~p"/devices/#{device.id}")

    view
    |> element("##{service.id}")
    |> render_click()

    render_async(view)

    render_submit(view, "submit-action", %{"action" => "NotAdvertised", "arguments" => %{}})
    assert has_element?(view, "#flash-error", "action is not available")

    view
    |> form("form[phx-value-action='ForceTermination']", %{})
    |> render_submit()

    view
    |> form("form[phx-value-action='GetExternalIPAddress']", %{})
    |> render_submit()

    assert has_element?(view, "#flash-error", "Finish the current action")
    refute_received {:action_invoked, _action, _arguments}
  end

  defp install_gateway_service do
    control_point = start_supervised!({TestActionControlPoint, test: self()})

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
