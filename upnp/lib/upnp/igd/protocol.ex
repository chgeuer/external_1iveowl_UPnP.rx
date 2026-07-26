defmodule UPnP.IGD.Protocol do
  @moduledoc "IGD transport protocol conversion."

  @type t :: :tcp | :udp

  @doc "Returns the protocol token required on the wire."
  @spec to_wire(t()) :: String.t()
  def to_wire(:tcp), do: "TCP"
  def to_wire(:udp), do: "UDP"

  @doc "Parses a protocol token leniently."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_protocol}
  def parse(value) when is_binary(value) do
    case String.upcase(String.trim(value)) do
      "TCP" -> {:ok, :tcp}
      "UDP" -> {:ok, :udp}
      _ -> {:error, :invalid_protocol}
    end
  end
end
