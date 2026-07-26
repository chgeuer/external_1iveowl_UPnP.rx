defmodule UPnP do
  @moduledoc """
  An OTP-native UPnP control point.

  Start a control point under your supervision tree:

      children = [
        {UPnP.ControlPoint, name: MyApp.UPnP, interfaces: :auto}
      ]

  Device and service values are immutable structs. Processes are used only for
  stateful protocol lifecycles such as discovery, event subscriptions, and
  renewable port mappings.
  """

  @doc """
  Starts a dynamically supervised control point.
  """
  @spec start_control_point(keyword()) :: DynamicSupervisor.on_start_child()
  def start_control_point(options \\ []) do
    DynamicSupervisor.start_child(UPnP.ControlPointSupervisor, {UPnP.ControlPoint, options})
  end

  @doc """
  Stops a dynamically supervised control point abruptly.

  Use `UPnP.ControlPoint.close/2` when graceful GENA cleanup is required.
  """
  @spec stop_control_point(GenServer.server()) :: :ok | {:error, :not_found}
  def stop_control_point(control_point) when is_pid(control_point) do
    DynamicSupervisor.terminate_child(UPnP.ControlPointSupervisor, control_point)
  end

  def stop_control_point(control_point) do
    case GenServer.whereis(control_point) do
      nil -> {:error, :not_found}
      pid -> stop_control_point(pid)
    end
  end
end
