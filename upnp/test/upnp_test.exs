defmodule UPnPTest do
  use ExUnit.Case, async: true

  test "application supervision starts shared infrastructure" do
    assert Process.whereis(UPnP.TaskSupervisor)
    assert Process.whereis(UPnP.ControlPointSupervisor)
    assert Process.whereis(UPnP.Finch)
  end
end
