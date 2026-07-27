defmodule UPnP do
  @moduledoc """
  An OTP-native UPnP control point.

  Start a control point under your supervision tree:

      children = [
        {UPnP.ControlPoint, name: MyApp.UPnP, interfaces: :auto}
      ]

  Each control point has a stable, monitorable lifecycle owner around isolated
  `UPnP.ControlPoint.Runtime` generations holding its SSDP interfaces,
  eventing processes, and tasks. One control point can therefore neither
  restart nor outlive another. Only the Finch pool, registry, dynamically
  supervised lifecycle owners, and IGD leases live at application scope.

  Device and service values are immutable structs. Processes are used only for
  stateful protocol lifecycles such as discovery, event subscriptions, and
  renewable port mappings.
  """

  @doc """
  Starts a dynamically supervised control point.

  The returned pid is the stable lifecycle owner. Pass it, or the `:name` given
  in `options`, to the `UPnP.ControlPoint` functions and monitor it to observe
  terminal control-point death.
  """
  @spec start_control_point(keyword()) :: DynamicSupervisor.on_start_child()
  def start_control_point(options \\ []) do
    DynamicSupervisor.start_child(UPnP.ControlPointSupervisor, {UPnP.ControlPoint, options})
  end

  @doc """
  Stops a dynamically supervised control point abruptly.

  The stable owner and current runtime generation are terminated without
  protocol goodbyes. Use `UPnP.ControlPoint.close/2` when graceful GENA cleanup
  is required.
  """
  @spec stop_control_point(GenServer.server()) :: :ok | {:error, :not_found}
  def stop_control_point(control_point) do
    case UPnP.ControlPoint.runtime(control_point) do
      nil -> {:error, :not_found}
      runtime -> DynamicSupervisor.terminate_child(UPnP.ControlPointSupervisor, runtime)
    end
  end
end
