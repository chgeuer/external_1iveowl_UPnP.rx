defmodule UpnpExplorer.ServiceViewTest do
  use ExUnit.Case, async: true

  alias UPnP.ActionResult
  alias UpnpExplorer.ServiceView

  test "projects declared outputs case-insensitively before device extensions" do
    action = %{
      id: "action-test",
      outputs: [
        %{id: "status", name: "NewConnectionStatus", wire_name: "NewConnectionStatus"},
        %{id: "uptime", name: "NewUptime", wire_name: "NewUptime"}
      ]
    }

    result = %ActionResult{
      out: %{
        "newconnectionstatus" => "Connected",
        "VendorExtension" => "ready"
      }
    }

    assert %{
             outputs: [
               %{name: "NewConnectionStatus", value: "Connected", returned?: true},
               %{name: "NewUptime", value: nil, returned?: false},
               %{name: "VendorExtension", value: "ready", declared?: false}
             ]
           } = ServiceView.action_result(action, result)
  end
end
