defmodule UPnP.Description.ParserTest do
  use ExUnit.Case, async: true

  alias UPnP.Description.Parser
  alias UPnP.ParseError

  test "parses nested devices and resolves all operational URLs against URLBase" do
    xml = """
    <?xml version="1.0"?>
    <d:ROOT xmlns:d="urn:schemas-upnp-org:device-1-0" CONFIGID="42">
      <d:URLBase>http://10.0.0.2:8080/upnp/</d:URLBase>
      <d:specVersion><d:major>2</d:major><d:minor>0</d:minor></d:specVersion>
      <d:DEVICE>
        <d:deviceType> urn:schemas-upnp-org:device:MediaServer:2 </d:deviceType>
        <d:friendlyName>Living Room & Media</d:friendlyName>
        <d:UDN>
          uuid:root-device
        </d:UDN>
        <d:manufacturer>D&M Holdings</d:manufacturer>
        <d:presentationURL>ui/index.html</d:presentationURL>
        <d:iconList>
          <d:icon>
            <d:mimetype>image/png</d:mimetype>
            <d:width>48</d:width><d:height>48</d:height><d:depth>24</d:depth>
            <d:url>../icons/device.png</d:url>
          </d:icon>
        </d:iconList>
        <d:serviceList>
          <d:service>
            <d:serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</d:serviceType>
            <d:serviceId>urn:upnp-org:serviceId:ContentDirectory</d:serviceId>
            <d:SCPDURL>content/scpd.xml</d:SCPDURL>
            <d:controlURL>/control/content</d:controlURL>
            <d:eventSubURL>events/content</d:eventSubURL>
          </d:service>
        </d:serviceList>
        <d:deviceList>
          <d:device>
            <d:deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</d:deviceType>
            <d:friendlyName>Embedded</d:friendlyName>
            <d:UDN>uuid:embedded</d:UDN>
            <d:serviceList>
              <d:service>
                <d:serviceType>urn:schemas-upnp-org:service:RenderingControl:1</d:serviceType>
                <d:controlURL>render/control</d:controlURL>
              </d:service>
            </d:serviceList>
          </d:device>
        </d:deviceList>
        <vendor:Extension xmlns:vendor="urn:vendor">ignored</vendor:Extension>
      </d:DEVICE>
    </d:ROOT>
    """

    assert {:ok, device} = Parser.parse(xml, "http://10.0.0.9/device/description.xml")
    assert device.config_id == 42
    assert device.spec_version.major == 2
    assert device.friendly_name == "Living Room & Media"
    assert device.manufacturer == "D&M Holdings"
    assert device.udn == "uuid:root-device"
    assert to_string(device.base_url) == "http://10.0.0.2:8080/upnp/"
    assert to_string(device.presentation_url) == "http://10.0.0.2:8080/upnp/ui/index.html"

    assert [icon] = device.icons
    assert icon.width == 48
    assert to_string(icon.url) == "http://10.0.0.2:8080/icons/device.png"

    assert [service] = device.services
    assert to_string(service.scpd_url) == "http://10.0.0.2:8080/upnp/content/scpd.xml"
    assert to_string(service.control_url) == "http://10.0.0.2:8080/control/content"
    assert to_string(service.event_sub_url) == "http://10.0.0.2:8080/upnp/events/content"

    assert [embedded] = device.embedded_devices
    assert embedded.friendly_name == "Embedded"

    assert to_string(hd(embedded.services).control_url) ==
             "http://10.0.0.2:8080/upnp/render/control"

    assert length(UPnP.DeviceDescription.self_and_descendants(device)) == 2
  end

  test "ignores relative URLBase and leaves malformed optional fields unset" do
    xml = """
    <root configId="not-a-number">
      <URLBase>/not/absolute</URLBase>
      <specVersion><major>broken</major><minor>7</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
        <UDN>uuid:basic</UDN>
        <presentationURL>http://[broken</presentationURL>
        <iconList>
          <icon><width>wide</width><url>icon.png</url></icon>
        </iconList>
        <serviceList>
          <service><controlURL>../control</controlURL></service>
        </serviceList>
      </device>
    </root>
    """

    assert {:ok, device} = Parser.parse(xml, "http://10.0.0.5:8080/dev/desc.xml")
    assert device.config_id == nil
    assert device.spec_version == nil
    assert device.presentation_url == nil
    assert hd(device.icons).width == nil
    assert to_string(hd(device.icons).url) == "http://10.0.0.5:8080/dev/icon.png"
    assert to_string(hd(device.services).control_url) == "http://10.0.0.5:8080/control"
  end

  test "returns inspectable parse errors when no device can be identified" do
    assert {:error, %ParseError{reason: :missing_device}} =
             Parser.parse("<root><specVersion/></root>", "http://10.0.0.1/desc.xml")

    assert {:error, %ParseError{source: :device_description}} =
             Parser.parse("<root><device>", "http://10.0.0.1/desc.xml")

    assert {:error, %ParseError{reason: :invalid_location}} =
             Parser.parse("<device/>", "/relative.xml")
  end

  test "unsupported encodings and invalid UTF-8 are errors, not exceptions" do
    assert {:error, %ParseError{}} =
             Parser.parse(
               ~s(<?xml version="1.0" encoding="iso-8859-1"?><device/>),
               "http://10.0.0.1/desc.xml"
             )

    assert {:error, %ParseError{reason: :invalid_utf8}} =
             Parser.parse(<<0xFF, 0xFE, 0x00>>, "http://10.0.0.1/desc.xml")
  end
end
