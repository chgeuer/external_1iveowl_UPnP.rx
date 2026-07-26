defmodule UPnP.Roster.Event do
  @moduledoc "A live change to the bounded device roster."

  @enforce_keys [:kind, :device]
  defstruct [:kind, :device]

  @type kind :: :appeared | :updated | :expired | :left
  @type t :: %__MODULE__{kind: kind(), device: UPnP.Device.t()}
end
