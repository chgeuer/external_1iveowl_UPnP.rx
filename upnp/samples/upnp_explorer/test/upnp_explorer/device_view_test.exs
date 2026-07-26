defmodule UpnpExplorer.DeviceViewTest do
  use ExUnit.Case, async: true

  alias UPnP.{
    DescribedDevice,
    Device,
    DeviceDescription,
    IconDescription,
    ServiceDescription
  }

  alias UpnpExplorer.DeviceView

  test "projects partial discovery immediately with a stable public identity" do
    device = device()

    first = DeviceView.from_discovered(device)
    second = DeviceView.from_discovered(device)

    assert first.id == second.id
    assert first.id =~ "device-"
    assert first.name == "Device at 192.0.2.10"
    assert first.status == :describing
    assert first.udn == "uuid:living-room"
    assert first.local_address == "192.0.2.20"
    assert first.remote_endpoint == "192.0.2.10:1900"
    assert DeviceView.matches?(first, "LIVING-ROOM")
    refute DeviceView.matches?(first, "printer")
  end

  test "projects descriptions into human capabilities and embedded device nodes" do
    root = %DeviceDescription{
      location: URI.parse("http://192.0.2.10/device.xml"),
      friendly_name: "Living Room Receiver",
      manufacturer: "Acme Audio",
      model_name: "Sound 100",
      device_type: "urn:schemas-upnp-org:device:MediaRenderer:1",
      udn: "uuid:living-room",
      icons: [
        %IconDescription{
          width: 48,
          height: 48,
          url: URI.parse("http://192.0.2.10/icon-small.png")
        },
        %IconDescription{
          width: 128,
          height: 128,
          url: URI.parse("http://192.0.2.10/icon-large.png")
        }
      ],
      services: [
        %ServiceDescription{
          service_type: "urn:schemas-upnp-org:service:RenderingControl:1",
          service_id: "urn:upnp-org:serviceId:RenderingControl",
          scpd_url: URI.parse("http://192.0.2.10/rendering.xml"),
          control_url: URI.parse("http://192.0.2.10/control"),
          event_sub_url: URI.parse("http://192.0.2.10/events")
        }
      ],
      embedded_devices: [
        %DeviceDescription{
          friendly_name: "Receiver clock",
          device_type: "urn:schemas-upnp-org:device:Clock:1",
          udn: "uuid:living-room-clock"
        }
      ]
    }

    described = %DescribedDevice{
      control_point: :test_control_point,
      device: device(),
      description: root
    }

    {view, services} = DeviceView.from_described(described)

    assert view.name == "Living Room Receiver"
    assert view.device_kind == "Media renderer"
    assert view.status == :online
    assert view.capabilities == ["Audio and display"]
    assert view.service_count == 1
    assert view.embedded_count == 1
    assert view.icon_url == "http://192.0.2.10/icon-large.png"
    assert DeviceView.matches?(view, "acme renderingcontrol")
    assert Map.keys(services) == Enum.map(view.services, & &1.id)
  end

  defp device do
    %Device{
      location: URI.parse("http://192.0.2.10/device.xml"),
      usn: "uuid:living-room::upnp:rootdevice",
      server: "Acme/1.0 UPnP/1.1",
      boot_id: 3,
      config_id: 9,
      max_age: 1_800,
      local_address: {192, 0, 2, 20},
      remote_endpoint: {{192, 0, 2, 10}, 1_900}
    }
  end
end
