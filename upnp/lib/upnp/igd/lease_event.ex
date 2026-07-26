defmodule UPnP.IGD.LeaseEvent do
  @moduledoc "A renewable port-mapping lease lifecycle event."

  @enforce_keys [:kind]
  defstruct [:kind, :reason]

  @type kind :: :renewed | :renewal_failed | :expired
  @type t :: %__MODULE__{kind: kind(), reason: term() | nil}
end
