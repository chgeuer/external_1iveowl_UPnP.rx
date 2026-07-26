defmodule UPnP.Eventing.AV.Parser do
  @moduledoc "AV event payload parsing."

  defdelegate parse(xml), to: UPnP.Eventing.AV.LastChange
end
