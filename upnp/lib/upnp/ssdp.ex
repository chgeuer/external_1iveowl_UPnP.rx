defmodule UPnP.SSDP do
  @moduledoc """
  SSDP datagram parsing and strict M-SEARCH composition.

  This facade is the public SSDP wire interface. Directional parser and composer
  modules are implementation details.
  """

  alias UPnP.SSDP.{Composer, Envelope, Parser, SearchTarget}

  @doc "Parses one SSDP response or NOTIFY datagram."
  @spec parse(binary()) :: {:ok, Envelope.t()} | {:error, :empty | :unsupported_message}
  def parse(datagram), do: Parser.parse(datagram)

  @doc "Composes a UDA 2.0 multicast M-SEARCH datagram."
  @spec m_search(SearchTarget.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def m_search(target, options), do: Composer.m_search(target, options)
end
