defmodule UpnpExplorer.ExplorerTest do
  use ExUnit.Case, async: true

  alias UpnpExplorer.Explorer

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
end
