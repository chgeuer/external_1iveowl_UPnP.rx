defmodule UPnP.IGD.Status do
  @moduledoc "The WAN connection state returned by `GetStatusInfo`."

  defstruct status: nil, last_error: nil, uptime: 0

  @type t :: %__MODULE__{
          status: String.t() | nil,
          last_error: String.t() | nil,
          uptime: non_neg_integer()
        }

  @doc "Reports whether the gateway says its WAN connection is connected."
  @spec connected?(t()) :: boolean()
  def connected?(%__MODULE__{status: status}) when is_binary(status),
    do: String.downcase(String.trim(status)) == "connected"

  def connected?(%__MODULE__{}), do: false
end
