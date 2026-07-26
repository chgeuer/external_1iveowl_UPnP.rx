defmodule UPnP.Eventing.PropertySetTest do
  use ExUnit.Case, async: true

  alias UPnP.Eventing.PropertySet

  test "parses case-insensitive property sets and decodes escaped payloads" do
    xml = """
    <E:PROPERTYSET xmlns:E="urn:schemas-upnp-org:event-1-0">
      <E:PROPERTY><SystemUpdateID>27</SystemUpdateID></E:PROPERTY>
      <E:PROPERTY><CurrentTrackTitle>Tom & Jerry</CurrentTrackTitle></E:PROPERTY>
      <E:PROPERTY>
        <LastChange>&lt;Event&gt;&lt;InstanceID val="0"/&gt;&lt;/Event&gt;</LastChange>
      </E:PROPERTY>
      <unknown>ignored</unknown>
    </E:PROPERTYSET>
    """

    assert {:ok, properties} = PropertySet.parse(xml)

    assert Enum.map(properties, & &1.name) == [
             "SystemUpdateID",
             "CurrentTrackTitle",
             "LastChange"
           ]

    assert Enum.at(properties, 1).value == "Tom & Jerry"
    assert Enum.at(properties, 2).value == ~s(<Event><InstanceID val="0"/></Event>)
  end

  test "an empty property set is a valid keep-alive" do
    assert {:ok, []} =
             PropertySet.parse(~s(<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"/>))
  end

  test "garbage and XML without a property set return parse errors" do
    assert {:error, %UPnP.ParseError{}} = PropertySet.parse("not xml")

    assert {:error, %UPnP.ParseError{reason: :missing_property_set}} =
             PropertySet.parse("<event/>")
  end
end
