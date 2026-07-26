defmodule UPnP.Async do
  @moduledoc false

  alias UPnP.Clock

  @type error :: :timeout | {:task_exit, term()}

  @spec run((-> result), keyword()) :: {:ok, result} | {:error, error()} when result: term()
  def run(function, options) when is_function(function, 0) do
    supervisor = Keyword.get(options, :supervisor, UPnP.TaskSupervisor)
    clock = Keyword.get(options, :clock, UPnP.Clock.System)
    timeout = Keyword.fetch!(options, :timeout)

    start_ref = make_ref()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          {:upnp_async_start, ^start_ref} -> function.()
        end
      end)

    timeout_ref = make_ref()
    timer = Clock.send_after(clock, self(), {:upnp_async_timeout, timeout_ref}, timeout)
    send(task.pid, {:upnp_async_start, start_ref})

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        Clock.cancel_timer(clock, timer)
        {:ok, result}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        Clock.cancel_timer(clock, timer)
        {:error, {:task_exit, reason}}

      {:upnp_async_timeout, ^timeout_ref} ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
