defmodule UPnP.SOAP do
  @moduledoc "SOAP request composition and response parsing."

  defdelegate compose(service_type, action_name, arguments \\ []),
    to: UPnP.SOAP.Composer

  defdelegate compose_action_request(service_type, action_name, arguments \\ []),
    to: UPnP.SOAP.Composer

  defdelegate soap_action_header(service_type, action_name),
    to: UPnP.SOAP.Composer

  defdelegate compose_soap_action_header(service_type, action_name),
    to: UPnP.SOAP.Composer

  defdelegate parse(xml, action_name), to: UPnP.SOAP.Parser
  defdelegate parse_response(xml, action_name), to: UPnP.SOAP.Parser
  defdelegate parse_action_response(xml, action_name), to: UPnP.SOAP.Parser
  defdelegate parse_fault(xml), to: UPnP.SOAP.Parser
end
