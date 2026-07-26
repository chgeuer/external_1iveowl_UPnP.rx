defmodule UPnP.Eventing.AV.LastChangeTest do
  use ExUnit.Case, async: true

  alias UPnP.Eventing.AV.LastChange
  alias UPnP.Eventing.AV.PropertyChange

  test "parses instances, channels, outside variables, text, and bare ampersands" do
    xml = """
    <a:EVENT xmlns:a="urn:schemas-upnp-org:metadata-1-0/RCS/">
      <a:INSTANCEID VAL="1">
        <a:Volume CHANNEL="Master" VAL="25"/>
        <a:CurrentTrackMetaData val="Tom & Jerry"/>
      </a:INSTANCEID>
      <a:InstanceID val="2">
        <a:TransportState>PAUSED_PLAYBACK</a:TransportState>
      </a:InstanceID>
      <a:Mute channel="Master" val="0"/>
    </a:EVENT>
    """

    assert {:ok, changes} = LastChange.parse(xml)

    assert changes == [
             %PropertyChange{
               instance_id: 1,
               name: "Volume",
               value: "25",
               channel: "Master"
             },
             %PropertyChange{
               instance_id: 1,
               name: "CurrentTrackMetaData",
               value: "Tom & Jerry"
             },
             %PropertyChange{
               instance_id: 2,
               name: "TransportState",
               value: "PAUSED_PLAYBACK"
             },
             %PropertyChange{
               instance_id: 0,
               name: "Mute",
               value: "0",
               channel: "Master"
             }
           ]
  end

  test "invalid instance ids become zero and empty events are valid" do
    assert {:ok, [%PropertyChange{instance_id: 0}]} =
             LastChange.parse(
               ~s(<Event><InstanceID val="bad"><State val="x"/></InstanceID></Event>)
             )

    assert {:ok, []} = LastChange.parse("<Event/>")
  end

  test "malformed payloads return ParseError data" do
    assert {:error, %UPnP.ParseError{source: :av_last_change}} =
             LastChange.parse("<Event>")
  end
end
