defmodule UPnP.AsyncTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual

  test "returns successful task results" do
    {:ok, clock} = start_supervised(Manual)

    assert {:ok, :done} =
             UPnP.Async.run(fn -> :done end,
               clock: {Manual, clock},
               timeout: 1_000
             )
  end

  test "cancels work when the injected clock reaches its deadline" do
    {:ok, clock} = start_supervised(Manual)
    parent = self()

    caller =
      Task.async(fn ->
        UPnP.Async.run(
          fn ->
            send(parent, :task_started)

            receive do
              :never -> :done
            end
          end,
          clock: {Manual, clock},
          timeout: 1_000
        )
      end)

    assert_receive :task_started
    :ok = Manual.advance(clock, 1_000)
    assert Task.await(caller) == {:error, :timeout}
  end
end
