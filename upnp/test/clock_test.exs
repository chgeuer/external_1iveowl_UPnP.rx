defmodule UPnP.ClockTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock
  alias UPnP.Clock.Manual

  defmodule Stateless do
    @behaviour Clock

    @impl true
    def monotonic_time(nil), do: 42

    @impl true
    def utc_now(nil), do: ~U[2000-01-01 00:00:00Z]

    @impl true
    def send_after(nil, destination, message, _milliseconds) do
      send(destination, message)
      make_ref()
    end

    @impl true
    def cancel_timer(nil, _timer_ref), do: false
  end

  test "module clocks normalize to stateless adapters" do
    assert Clock.normalize(Stateless) == {Stateless, nil}
    assert Clock.monotonic_time(Stateless) == 42
    assert Clock.utc_now(Stateless) == ~U[2000-01-01 00:00:00Z]

    timer = Clock.send_after(Stateless, self(), :stateless, 0)
    assert is_reference(timer)
    assert_receive :stateless
    refute Clock.cancel_timer(Stateless, timer)
  end

  test "manual clock supports its documented default start" do
    assert {:ok, clock} = Manual.start_link()
    assert Clock.monotonic_time({Manual, clock}) == 0
    GenServer.stop(clock)
  end

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

  test "cancelling an unknown manual timer is a tagged no-op" do
    {:ok, clock} = start_supervised(Manual)
    refute Clock.cancel_timer({Manual, clock}, make_ref())
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
