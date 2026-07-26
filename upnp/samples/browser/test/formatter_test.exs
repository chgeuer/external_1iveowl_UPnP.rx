defmodule UPnP.Samples.DeviceTreeTest do
  use ExUnit.Case, async: true

  alias UPnP.{DeviceDescription, ServiceDescription}

  test "renders services before embedded devices with matching tree connectors" do
    description = %DeviceDescription{
      location: URI.parse("http://192.168.1.2:49000/igd2desc.xml"),
      friendly_name: "InternetGatewayDeviceV2 - fritzbox",
      device_type: "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
      manufacturer: "AVM Berlin",
      model_name: "FRITZ!Box 6890 LTE",
      services: [
        %ServiceDescription{service_type: "urn:schemas-any-com:service:Any:1"}
      ],
      embedded_devices: [
        %DeviceDescription{
          device_type: "urn:schemas-upnp-org:device:WANDevice:2",
          manufacturer: "AVM Berlin",
          model_name: "WANDevice - FRITZ!Box 6890 LTE",
          services: [
            %ServiceDescription{
              service_type: "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"
            }
          ],
          embedded_devices: [
            %DeviceDescription{
              device_type: "urn:schemas-upnp-org:device:WANConnectionDevice:2",
              manufacturer: "AVM Berlin",
              model_name: "WANConnectionDevice - FRITZ!Box 6890 LTE",
              services: [
                %ServiceDescription{
                  service_type: "urn:schemas-upnp-org:service:WANIPConnection:2"
                }
              ]
            }
          ]
        }
      ]
    }

    assert UPnP.Samples.DeviceTree.render(description) == """
           InternetGatewayDeviceV2 - fritzbox  [http://192.168.1.2:49000/igd2desc.xml]
           urn:schemas-upnp-org:device:InternetGatewayDevice:2  (AVM Berlin FRITZ!Box 6890 LTE)
           ├─ · urn:schemas-any-com:service:Any:1
           └─ urn:schemas-upnp-org:device:WANDevice:2  (AVM Berlin WANDevice - FRITZ!Box 6890 LTE)
              ├─ · urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1
              └─ urn:schemas-upnp-org:device:WANConnectionDevice:2  (AVM Berlin WANConnectionDevice - FRITZ!Box 6890 LTE)
                 └─ · urn:schemas-upnp-org:service:WANIPConnection:2

           """
  end
end
