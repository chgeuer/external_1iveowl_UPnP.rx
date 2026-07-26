defmodule UPnPTest do
  use ExUnit.Case, async: true

  test "application supervision starts shared infrastructure" do
    assert Process.whereis(UPnP.TaskSupervisor)
    assert Process.whereis(UPnP.ControlPointSupervisor)
    assert Process.whereis(UPnP.Finch)
    assert Process.whereis(UPnP.Registry)
    assert Process.whereis(UPnP.IGD.LeaseSupervisor)
  end

  test "application supervision owns no control-point-scoped processes" do
    children =
      UPnP.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.sort()

    assert children == [
             UPnP.ControlPointSupervisor,
             UPnP.Finch,
             UPnP.IGD.LeaseSupervisor,
             UPnP.Registry,
             UPnP.TaskSupervisor
           ]
  end
end
