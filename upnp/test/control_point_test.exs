defmodule UPnP.ControlPointTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.ControlPoint
  alias UPnP.Roster.Event
  alias UPnP.SSDP.Envelope

  @maximum_roster_age_ms 86_400_000
  @memory_growth_allowance_bytes 262_144

  setup do
    {:ok, clock} = start_supervised(Manual)

    {:ok, control_point} =
      start_supervised(
        {ControlPoint, interfaces: [], clock: {Manual, clock}, roster_expiry_fallback: 30_000}
      )

    %{clock: clock, control_point: control_point}
  end

  test "roster returns an atomic snapshot then live changes", %{control_point: control_point} do
    assert {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    envelope = alive("uuid:one::upnp:rootdevice", 1)
    :ok = ControlPoint.inject(control_point, envelope)
    [_device] = ControlPoint.roster(control_point)

    assert_receive {:upnp, ref, %Event{kind: :appeared, device: device}}
    assert ref == subscription.ref
    assert device.usn == envelope.usn

    assert {:ok, _late_subscription, [snapshot]} =
             ControlPoint.subscribe_roster(control_point)

    assert snapshot.usn == envelope.usn
  end

  test "reboot updates and max-age expiry remove a device", %{
    clock: clock,
    control_point: control_point
  } do
    {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)
    ControlPoint.inject(control_point, alive("uuid:one::upnp:rootdevice", 1, 2))
    [_device] = ControlPoint.roster(control_point)
    assert_receive {:upnp, _, %Event{kind: :appeared}}

    ControlPoint.inject(control_point, alive("uuid:one::upnp:rootdevice", 2, 2))
    [_device] = ControlPoint.roster(control_point)
    assert_receive {:upnp, _, %Event{kind: :updated}}

    :ok = Manual.advance(clock, 2_001)
    assert_receive {:upnp, ref, %Event{kind: :expired}}
    assert ref == subscription.ref
    assert ControlPoint.roster(control_point) == []
  end

  test "untrusted max-age is clamped before the system timer is scheduled" do
    control_point =
      start_supervised!(
        {ControlPoint, interfaces: [], clock: UPnP.Clock.System},
        id: :system_clock_control_point
      )

    coordinator = ControlPoint.whereis(control_point)
    monitor = Process.monitor(coordinator)

    :ok =
      ControlPoint.inject(
        control_point,
        alive("uuid:hostile::upnp:rootdevice", 1, 9_223_372_036)
      )

    state = :sys.get_state(coordinator)

    refute_receive {:DOWN, ^monitor, :process, ^coordinator, _reason}
    assert Process.alive?(coordinator)

    assert %{expiry_timer: expiry_timer} = state.roster["uuid:hostile"]
    remaining = Process.read_timer(expiry_timer)
    assert is_integer(remaining)
    assert remaining <= @maximum_roster_age_ms
    assert remaining > @maximum_roster_age_ms - 5_000
  end

  test "unique identities cannot grow the roster or expiry timers past the configured cap", %{
    clock: clock
  } do
    cap = 8

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [],
         clock: {Manual, clock},
         max_roster_entries: cap,
         roster_expiry_fallback: 30_000},
        id: :bounded_roster_control_point
      )

    {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    Enum.each(1..(cap * 4), fn identity ->
      usn = "uuid:#{String.pad_leading(Integer.to_string(identity), 3, "0")}::upnp:rootdevice"
      inject_and_sync(control_point, alive(usn, 1))
      :ok = Manual.advance(clock, 1)
    end)

    coordinator = ControlPoint.whereis(control_point)
    state = :sys.get_state(coordinator)
    timers = roster_timers(clock)

    assert map_size(state.roster) == cap
    assert :gb_trees.size(state.roster_order) == cap
    assert map_size(timers) == cap

    assert MapSet.new(Map.keys(state.roster)) ==
             MapSet.new(
               Enum.map(25..32, &"uuid:#{String.pad_leading(Integer.to_string(&1), 3, "0")}")
             )

    assert Enum.all?(state.roster, fn {_identity, entry} ->
             Map.has_key?(timers, entry.expiry_timer)
           end)

    events = receive_roster_events(subscription.ref, cap * 7)
    assert Enum.frequencies_by(events, & &1.kind) == %{appeared: cap * 4, expired: cap * 3}
  end

  test "coordinator memory remains bounded under sustained unique-identity injection", %{
    clock: clock
  } do
    cap = 16

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [],
         clock: {Manual, clock},
         max_roster_entries: cap,
         roster_expiry_fallback: 30_000},
        id: :memory_bounded_roster_control_point
      )

    coordinator = ControlPoint.whereis(control_point)

    memory_samples =
      Enum.map(0..7, fn batch ->
        Enum.each(1..256, fn offset ->
          identity = batch * 256 + offset
          usn = "uuid:flood-#{String.pad_leading(Integer.to_string(identity), 5, "0")}"
          :ok = ControlPoint.inject(control_point, alive(usn, 1))
        end)

        _options = ControlPoint.options(control_point)
        :erlang.garbage_collect(coordinator)
        process_memory(coordinator)
      end)

    [first_sample | _remaining] = memory_samples
    assert Enum.max(memory_samples) <= first_sample + @memory_growth_allowance_bytes

    state = :sys.get_state(coordinator)
    assert map_size(state.roster) == cap
    assert :gb_trees.size(state.roster_order) == cap
    assert clock |> roster_timers() |> map_size() == cap
  end

  test "byebye removes the matching USN and announces a deliberate departure", %{
    control_point: control_point
  } do
    {:ok, roster_subscription, []} = ControlPoint.subscribe_roster(control_point)
    {:ok, announcement_subscription} = ControlPoint.subscribe_announcements(control_point)

    ControlPoint.inject(control_point, alive("uuid:one::upnp:rootdevice", 1))
    [_device] = ControlPoint.roster(control_point)
    assert_receive {:upnp, _, %Event{kind: :appeared}}
    assert_receive {:upnp, _, %UPnP.Announcement{kind: :alive}}

    ControlPoint.inject(control_point, %Envelope{
      kind: :byebye,
      usn: "uuid:one::upnp:rootdevice"
    })

    [] = ControlPoint.roster(control_point)
    assert_receive {:upnp, roster_ref, %Event{kind: :left}}
    assert roster_ref == roster_subscription.ref

    assert_receive {:upnp, announcement_ref, %UPnP.Announcement{kind: :byebye}}
    assert announcement_ref == announcement_subscription.ref
  end

  test "byebye and max-age expiry prune document caches", %{
    clock: clock,
    control_point: control_point
  } do
    byebye_envelope = alive("uuid:byebye::upnp:rootdevice", 1)
    inject_and_sync(control_point, byebye_envelope)
    [byebye_device] = ControlPoint.roster(control_point)
    seed_document_caches(control_point, byebye_device)

    :ok =
      ControlPoint.inject(control_point, %Envelope{
        kind: :byebye,
        usn: byebye_envelope.usn
      })

    assert ControlPoint.roster(control_point) == []
    assert_document_caches_empty(control_point)

    {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)
    expiring_envelope = alive("uuid:expiring::upnp:rootdevice", 1, 1)
    inject_and_sync(control_point, expiring_envelope)
    [expiring_device] = ControlPoint.roster(control_point)
    seed_document_caches(control_point, expiring_device)

    :ok = Manual.advance(clock, 1_001)
    assert_receive {:upnp, ref, %Event{kind: :expired}}
    assert ref == subscription.ref
    assert ControlPoint.roster(control_point) == []
    assert_document_caches_empty(control_point)
  end

  test "one-shot discovery deduplicates by device and boot", %{
    clock: clock,
    control_point: control_point
  } do
    coordinator = ControlPoint.whereis(control_point)
    request = :gen_server.send_request(coordinator, {:discover, [mx: 1]})
    _state = :sys.get_state(coordinator)
    envelope = alive("uuid:one::upnp:rootdevice", 1)

    ControlPoint.inject(control_point, %{
      envelope
      | kind: :search_response,
        search_target: "upnp:rootdevice"
    })

    ControlPoint.inject(control_point, %{
      envelope
      | kind: :search_response,
        search_target: "upnp:rootdevice"
    })

    :ok = Manual.advance(clock, 1_250)
    assert {:reply, {:ok, [device]}} = :gen_server.wait_response(request, :infinity)
    assert device.usn == envelope.usn
  end

  test "subscription is removed when its owner exits", %{control_point: control_point} do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)
        send(parent, {:subscribed, subscription.ref})
      end)

    monitor = Process.monitor(pid)
    assert_receive {:subscribed, ref}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    ControlPoint.inject(control_point, alive("uuid:one::upnp:rootdevice", 1))
    [_device] = ControlPoint.roster(control_point)
    refute_receive {:upnp, ^ref, _}
  end

  test "unidentifiable announcements and missing SCPD URLs stay tagged", %{
    control_point: control_point
  } do
    :ok =
      ControlPoint.inject(control_point, %Envelope{
        kind: :alive,
        usn: "uuid:missing-location::upnp:rootdevice",
        location: nil
      })

    assert ControlPoint.roster(control_point) == []

    assert ControlPoint.get_scpd(control_point, %UPnP.ServiceDescription{}, :missing) ==
             {:error, :missing_scpd_url}
  end

  defp alive(usn, boot_id, max_age \\ 30) do
    %Envelope{
      kind: :alive,
      usn: usn,
      boot_id: boot_id,
      max_age: max_age,
      notification_type: "upnp:rootdevice",
      location: URI.parse("http://192.0.2.1/device.xml")
    }
  end

  defp inject_and_sync(control_point, envelope) do
    :ok = ControlPoint.inject(control_point, envelope)
    _options = ControlPoint.options(control_point)
    :ok
  end

  defp receive_roster_events(ref, count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:upnp, ^ref, %Event{} = event}
      event
    end)
  end

  defp process_memory(process) do
    {:memory, bytes} = Process.info(process, :memory)
    bytes
  end

  defp roster_timers(clock) do
    clock
    |> :sys.get_state()
    |> Map.fetch!(:timers)
    |> Map.filter(fn {_ref, {_due_at, _sequence, _destination, message}} ->
      match?({:expire, _key, _seen_at}, message)
    end)
  end

  defp seed_document_caches(control_point, device) do
    coordinator = ControlPoint.whereis(control_point)
    location = URI.to_string(device.location)
    description_key = {location, device.config_id, device.boot_id}
    scpd_key = {description_key, "#{location}/scpd.xml"}

    :sys.replace_state(coordinator, fn state ->
      %{
        state
        | description_cache: Map.put(state.description_cache, description_key, :description),
          scpd_cache: Map.put(state.scpd_cache, scpd_key, :scpd)
      }
    end)
  end

  defp assert_document_caches_empty(control_point) do
    state = control_point |> ControlPoint.whereis() |> :sys.get_state()
    assert state.description_cache == %{}
    assert state.scpd_cache == %{}
  end
end
