defmodule UPnP.ControlPointTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.ControlPoint
  alias UPnP.Roster.Event
  alias UPnP.SSDP.Envelope

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
    assert_receive {:upnp, _, %Event{kind: :appeared}}

    ControlPoint.inject(control_point, alive("uuid:one::upnp:rootdevice", 2, 2))
    assert_receive {:upnp, _, %Event{kind: :updated}}

    :ok = Manual.advance(clock, 2_001)
    assert_receive {:upnp, ref, %Event{kind: :expired}}
    assert ref == subscription.ref
    assert ControlPoint.roster(control_point) == []
  end

  test "byebye removes the matching USN and announces a deliberate departure", %{
    control_point: control_point
  } do
    {:ok, roster_subscription, []} = ControlPoint.subscribe_roster(control_point)
    {:ok, announcement_subscription} = ControlPoint.subscribe_announcements(control_point)

    ControlPoint.inject(control_point, alive("uuid:one::upnp:rootdevice", 1))
    assert_receive {:upnp, _, %Event{kind: :appeared}}
    assert_receive {:upnp, _, %UPnP.Announcement{kind: :alive}}

    ControlPoint.inject(control_point, %Envelope{
      kind: :byebye,
      usn: "uuid:one::upnp:rootdevice"
    })

    assert_receive {:upnp, roster_ref, %Event{kind: :left}}
    assert roster_ref == roster_subscription.ref

    assert_receive {:upnp, announcement_ref, %UPnP.Announcement{kind: :byebye}}
    assert announcement_ref == announcement_subscription.ref
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
    refute_receive {:upnp, ^ref, _}
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
end
