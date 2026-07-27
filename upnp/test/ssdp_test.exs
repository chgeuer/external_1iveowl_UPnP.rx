defmodule UPnP.SSDPTest do
  use ExUnit.Case, async: true

  alias UPnP.SSDP
  alias UPnP.SSDP.SearchTarget

  test "constructs and validates every standard search target" do
    assert SearchTarget.all().value == "ssdp:all"

    assert SearchTarget.device_type("MediaServer").value ==
             "urn:schemas-upnp-org:device:MediaServer:1"

    assert SearchTarget.device_type("MediaRenderer", 3).value ==
             "urn:schemas-upnp-org:device:MediaRenderer:3"

    assert SearchTarget.service_type("ContentDirectory").value ==
             "urn:schemas-upnp-org:service:ContentDirectory:1"

    assert SearchTarget.service_type("RenderingControl", 2).value ==
             "urn:schemas-upnp-org:service:RenderingControl:2"

    assert SearchTarget.uuid("device-id").value == "uuid:device-id"
    assert SearchTarget.uuid("uuid:device-id").value == "uuid:device-id"
    assert {:ok, %SearchTarget{value: "vendor:target"}} = SearchTarget.new("vendor:target")

    for invalid <- ["", "target\rheader", "target\nheader"] do
      assert {:error, :invalid_search_target} = SearchTarget.new(invalid)
    end
  end

  test "parses a search response and its UDA headers" do
    message = """
    HTTP/1.1 200 OK\r
    CACHE-CONTROL: max-age=1800\r
    LOCATION: http://192.0.2.1:49000/igddesc.xml\r
    SERVER: ExampleOS/1 UPnP/2.0 Router/1\r
    ST: upnp:rootdevice\r
    USN: uuid:router::upnp:rootdevice\r
    BOOTID.UPNP.ORG: 7\r
    CONFIGID.UPNP.ORG: 12\r
    \r
    """

    assert {:ok, envelope} = SSDP.parse(message)
    assert envelope.kind == :search_response
    assert URI.to_string(envelope.location) == "http://192.0.2.1:49000/igddesc.xml"
    assert envelope.usn == "uuid:router::upnp:rootdevice"
    assert envelope.boot_id == 7
    assert envelope.config_id == 12
    assert envelope.max_age == 1800
    refute envelope.parsing_error?
  end

  test "clamps cache lifetimes that reach or exceed the BEAM timer boundary" do
    for seconds <- [9_223_372_035, 99_999_999_999] do
      message =
        "HTTP/1.1 200 OK\r\n" <>
          "CACHE-CONTROL: max-age=#{seconds}\r\n" <>
          "USN: uuid:hostile::upnp:rootdevice\r\n\r\n"

      assert {:ok, envelope} = SSDP.parse(message)
      assert envelope.max_age == 86_400
      refute envelope.parsing_error?
    end
  end

  test "keeps a malformed cache lifetime as degraded optional data" do
    message =
      "HTTP/1.1 200 OK\r\n" <>
        "CACHE-CONTROL: max-age=not-a-number\r\n" <>
        "USN: uuid:degraded::upnp:rootdevice\r\n\r\n"

    assert {:ok, envelope} = SSDP.parse(message)
    assert envelope.max_age == nil
    assert envelope.parsing_error?
  end

  test "keeps a degraded but identifiable notification" do
    message =
      "NOTIFY * HTTP/1.1\n" <>
        "NT: upnp:rootdevice\n" <>
        "NTS: ssdp:alive\n" <>
        "USN: uuid:device::upnp:rootdevice\n" <>
        "LOCATION: not a URI\n" <>
        "BROKEN HEADER\n\n"

    assert {:ok, envelope} = SSDP.parse(message)
    assert envelope.kind == :alive
    assert envelope.usn == "uuid:device::upnp:rootdevice"
    assert envelope.location == nil
    assert envelope.parsing_error?
  end

  test "parses byebye without requiring a location" do
    message =
      "NOTIFY * HTTP/1.1\r\n" <>
        "NT: upnp:rootdevice\r\n" <>
        "NTS: ssdp:byebye\r\n" <>
        "USN: uuid:device::upnp:rootdevice\r\n\r\n"

    assert {:ok, envelope} = SSDP.parse(message)
    assert envelope.kind == :byebye
    refute envelope.parsing_error?
  end

  test "composes an exact, injection-safe multicast search" do
    assert {:ok, message} =
             SSDP.m_search(SearchTarget.root_device(),
               mx: 3,
               friendly_name: "My Control Point",
               user_agent: "Elixir/1 UPnP/2.0 upnp/0.1"
             )

    assert message =~ "M-SEARCH * HTTP/1.1\r\n"
    assert message =~ "HOST: 239.255.255.250:1900\r\n"
    assert message =~ "MAN: \"ssdp:discover\"\r\n"
    assert message =~ "CPFN.UPNP.ORG: My Control Point\r\n"
    assert String.ends_with?(message, "\r\n\r\n")

    assert {:error, :invalid_header_value} =
             SSDP.m_search(SearchTarget.root_device(), friendly_name: "bad\r\nX: injected")

    assert {:error, :invalid_mx} = SSDP.m_search(SearchTarget.root_device(), mx: :invalid)
  end
end
