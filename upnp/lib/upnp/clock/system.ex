defmodule UPnP.Clock.System do
  @moduledoc """
  Production clock backed by BEAM monotonic time and process timers.
  """

  @behaviour UPnP.Clock

  @impl true
  def monotonic_time(_state), do: System.monotonic_time(:millisecond)

  @impl true
  def utc_now(_state), do: DateTime.utc_now()

  @impl true
  def send_after(_state, destination, message, milliseconds) do
    Process.send_after(destination, message, milliseconds)
  end

  @impl true
  def cancel_timer(_state, timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
  end
end
