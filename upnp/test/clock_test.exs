defmodule UPnP.ClockTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock
  alias UPnP.Clock.Manual

  test "manual clock advances monotonic and UTC time and releases due timers" do
    {:ok, clock} = start_supervised(Manual)
    spec = {Manual, clock}

    timer = Clock.send_after(spec, self(), :later, 500)
    assert is_reference(timer)
    refute_receive :later

    :ok = Manual.advance(clock, 499)
    refute_receive :later
    assert Clock.monotonic_time(spec) == 499

    :ok = Manual.advance(clock, 1)
    assert_receive :later
    assert Clock.utc_now(spec) == ~U[2000-01-01 00:00:00.500Z]
  end

  test "manual timers can be cancelled" do
    {:ok, clock} = start_supervised(Manual)
    spec = {Manual, clock}

    timer = Clock.send_after(spec, self(), :cancelled, 10)
    assert Clock.cancel_timer(spec, timer) == 10
    :ok = Manual.advance(clock, 10)
    refute_receive :cancelled
  end

  test "manual timers with the same due time preserve insertion order" do
    {:ok, clock} = start_supervised(Manual)
    spec = {Manual, clock}

    Clock.send_after(spec, self(), :first, 10)
    Clock.send_after(spec, self(), :second, 10)

    :ok = Manual.advance(clock, 10)
    assert_receive :first
    assert_receive :second
  end
end
