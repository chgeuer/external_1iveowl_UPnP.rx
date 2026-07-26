defmodule UPnP.HTTP.Response do
  @moduledoc "A bounded raw HTTP response."

  @enforce_keys [:status]
  defstruct status: nil, headers: [], body: ""

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc "Returns the first case-insensitive header value."
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) when is_binary(name) do
    downcased = String.downcase(name)

    Enum.find_value(headers, fn {header_name, value} ->
      if String.downcase(header_name) == downcased, do: value
    end)
  end
end
