defmodule UPnP.ActionResult do
  @moduledoc "The output arguments returned by a successful SOAP action."

  defstruct out: %{}

  @type t :: %__MODULE__{out: %{optional(binary()) => binary()}}

  @doc "Looks up an output argument case-insensitively."
  @spec get(t(), binary()) :: binary() | nil
  def get(%__MODULE__{out: out}, name) when is_binary(name) do
    if String.valid?(name) do
      folded_name = String.downcase(name)

      Enum.find_value(out, fn
        {key, value} when is_binary(key) ->
          if String.valid?(key) and String.downcase(key) == folded_name, do: value

        _entry ->
          nil
      end)
    end
  end
end
