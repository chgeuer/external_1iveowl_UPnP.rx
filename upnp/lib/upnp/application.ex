defmodule UPnP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: UPnP.Registry},
      {Task.Supervisor, name: UPnP.TaskSupervisor},
      {Finch, name: UPnP.Finch},
      {DynamicSupervisor, name: UPnP.ControlPointSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: UPnP.IGD.LeaseSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: UPnP.Supervisor)
  end
end
