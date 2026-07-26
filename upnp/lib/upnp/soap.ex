defmodule UPnP.SOAP do
  @moduledoc """
  Strict SOAP 1.1 request composition and lenient response parsing.

  This facade is the public SOAP wire interface. Directional parser and composer
  modules are implementation details.
  """

  alias UPnP.{ActionResult, ParseError, UpnpError}
  alias UPnP.SOAP.{Composer, Parser}

  @typedoc "Ordered argument pairs or a map of argument names to values."
  @type arguments :: [{binary(), binary()}] | %{optional(binary()) => binary()}

  @typedoc "A parsed SOAP action result or UPnP fault."
  @type parsed_response ::
          {:action_result, ActionResult.t()} | {:upnp_error, UpnpError.t()}

  @doc "Composes an XML SOAP 1.1 action request."
  @spec compose(binary(), binary(), arguments()) ::
          {:ok, binary()} | {:error, ParseError.t()}
  def compose(service_type, action_name, arguments) do
    Composer.compose(service_type, action_name, arguments)
  end

  @doc "Composes the quoted value of the HTTP SOAPACTION header."
  @spec soap_action_header(binary(), binary()) ::
          {:ok, binary()} | {:error, ParseError.t()}
  def soap_action_header(service_type, action_name) do
    Composer.soap_action_header(service_type, action_name)
  end

  @doc "Parses either an action result or a UPnP fault without relying on HTTP status."
  @spec parse(binary(), binary()) ::
          {:ok, parsed_response()} | {:error, ParseError.t()}
  def parse(xml, action_name), do: Parser.parse(xml, action_name)

  @doc "Parses a UPnPError from a SOAP Fault at any nesting depth."
  @spec parse_fault(binary()) :: {:ok, UpnpError.t()} | {:error, ParseError.t()}
  def parse_fault(xml), do: Parser.parse_fault(xml)
end
