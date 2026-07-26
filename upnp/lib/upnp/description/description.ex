defmodule UPnP.Description do
  @moduledoc "Device description wire parsing."

  defdelegate parse(xml, location), to: UPnP.Description.Parser
  defdelegate parse_device_description(xml, location), to: UPnP.Description.Parser
end
