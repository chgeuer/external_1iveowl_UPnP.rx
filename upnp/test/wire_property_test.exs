defmodule UPnP.WirePropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias UPnP.{Description, Eventing, SCPD, SOAP, SSDP, XML}

  @location URI.parse("http://192.0.2.1/device.xml")

  property "receive-side wire parsers are total for bounded arbitrary bytes" do
    check all(payload <- binary(max_length: 256)) do
      results = [
        Description.parse(payload, @location),
        SCPD.parse(payload),
        SOAP.parse(payload, "Action"),
        SOAP.parse_fault(payload),
        Eventing.PropertySet.parse(payload),
        Eventing.AV.LastChange.parse(payload),
        SSDP.parse(payload)
      ]

      assert Enum.all?(results, fn
               {:ok, _value} -> true
               {:error, _reason} -> true
               _other -> false
             end)
    end
  end

  property "SOAP composition round-trips XML-sensitive argument values" do
    fragment = member_of(["text", "<", ">", "&", "\"", "'", "\n", "\t"])

    check all(fragments <- list_of(fragment, max_length: 24)) do
      value = Enum.join(fragments)

      assert {:ok, body} =
               SOAP.compose("urn:schemas-upnp-org:service:Example:1", "SetValue", [
                 {"Value", value}
               ])

      assert {:ok, document} = XML.parse(body, :soap_property)
      assert {_name, _attributes, _content} = value_element = XML.find_first(document, "Value")
      assert XML.text(value_element) == value
    end
  end
end
