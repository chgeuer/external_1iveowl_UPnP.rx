defmodule UpnpExplorer.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        UpnpExplorerWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:upnp_explorer, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: UpnpExplorer.PubSub},
        {Task.Supervisor, name: UpnpExplorer.TaskSupervisor}
      ] ++
        network_children() ++
        [
          UpnpExplorerWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: UpnpExplorer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UpnpExplorerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp network_children do
    if Application.get_env(:upnp_explorer, :start_upnp, true) do
      [
        {UPnP.ControlPoint, name: UpnpExplorer.ControlPoint},
        {UpnpExplorer.Explorer, control_point: UpnpExplorer.ControlPoint}
      ]
    else
      [{UpnpExplorer.Explorer, control_point: nil}]
    end
  end
end
