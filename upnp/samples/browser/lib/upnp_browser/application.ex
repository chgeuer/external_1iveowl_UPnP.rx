defmodule UPnPBrowser.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, addresses} <- UPnP.Samples.Interfaces.ipv4_addresses(),
         false <- addresses == [] do
      children = [
        {Task.Supervisor, name: UPnPBrowser.TaskSupervisor},
        {UPnP.ControlPoint, name: UPnPBrowser.ControlPoint, interfaces: addresses},
        {UPnPBrowser.Browser,
         control_point: UPnPBrowser.ControlPoint,
         addresses: addresses,
         input: System.get_env("UPNP_BROWSER_NO_INPUT") != "1"}
      ]

      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: UPnPBrowser.Supervisor
      )
    else
      true ->
        IO.puts(:stderr, "No usable IPv4 interfaces found.")
        {:error, :no_usable_ipv4_interfaces}

      {:error, reason} ->
        IO.puts(:stderr, "Could not enumerate IPv4 interfaces: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
