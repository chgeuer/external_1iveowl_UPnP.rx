defmodule UPnP.SOAPTest do
  use ExUnit.Case, async: true

  alias UPnP.SOAP

  test "composer emits the exact SOAP 1.1 envelope and escapes values" do
    assert {:ok, body} =
             SOAP.compose(
               "urn:schemas-upnp-org:service:WANIPConnection:2",
               "AddPortMapping",
               [
                 {"NewRemoteHost", ""},
                 {"NewDescription", ~s(<router & "friends" 'test'>)}
               ]
             )

    assert body ==
             "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" <>
               "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " <>
               "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" <>
               "<s:Body><u:AddPortMapping " <>
               "xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:2\">" <>
               "<NewRemoteHost></NewRemoteHost>" <>
               "<NewDescription>&lt;router &amp; &quot;friends&quot; " <>
               "&apos;test&apos;&gt;</NewDescription>" <>
               "</u:AddPortMapping></s:Body></s:Envelope>"

    assert {:ok, ~s("urn:schemas-upnp-org:service:WANIPConnection:2#AddPortMapping")} =
             SOAP.soap_action_header(
               "urn:schemas-upnp-org:service:WANIPConnection:2",
               "AddPortMapping"
             )
  end

  test "composer rejects invalid names as parse errors" do
    assert {:error, %UPnP.ParseError{source: :soap_request}} =
             SOAP.compose("urn:service", "Bad Action", [])

    assert {:error, %UPnP.ParseError{}} =
             SOAP.compose("urn:service", "Action", [{"Bad Name", "x"}])

    assert {:error, %UPnP.ParseError{reason: :invalid_argument_value}} =
             SOAP.compose("urn:service", "Action", [{"Value", <<0>>}])

    assert {:error, %UPnP.ParseError{}} =
             SOAP.compose("urn:service", "Action", [{<<0xFF>>, "x"}])
  end

  test "parser finds a nested action response and keeps first duplicate output" do
    xml = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <wrapper>
          <u:GetStatusInfoResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:2">
            <NewConnectionStatus>Connected & Ready</NewConnectionStatus>
            <newconnectionstatus>duplicate</newconnectionstatus>
            <NewUptime>123</NewUptime>
          </u:GetStatusInfoResponse>
        </wrapper>
      </s:Body>
    </s:Envelope>
    """

    assert {:ok, {:action_result, result}} = SOAP.parse(xml, "GetStatusInfo")
    assert result.out["NewConnectionStatus"] == "Connected & Ready"
    assert result.out["NewUptime"] == "123"
    assert UPnP.ActionResult.get(result, "newconnectionstatus") == "Connected & Ready"
  end

  test "parser extracts a UPnPError fault despite sloppy nesting and casing" do
    xml = """
    <S:Envelope xmlns:S="http://schemas.xmlsoap.org/soap/envelope/">
      <S:Body>
        <S:FAULT>
          <faultcode>S:Client</faultcode>
          <detail><wrapper>
            <x:upnperror xmlns:x="urn:schemas-upnp-org:control-1-0">
              <x:ERRORCODE>718</x:ERRORCODE>
              <x:errorDescription>ConflictInMappingEntry</x:errorDescription>
            </x:upnperror>
          </wrapper></detail>
        </S:FAULT>
      </S:Body>
    </S:Envelope>
    """

    assert {:ok, error} = SOAP.parse_fault(xml)
    assert error.code == 718
    assert error.description == "ConflictInMappingEntry"
    assert {:ok, {:upnp_error, ^error}} = SOAP.parse(xml, "AddPortMapping")
  end

  test "malformed and unidentified SOAP bodies fail without raising" do
    assert {:error, %UPnP.ParseError{}} = SOAP.parse("not XML", "Get")

    assert {:error, %UPnP.ParseError{reason: :missing_action_response}} =
             SOAP.parse("<Envelope><Body/></Envelope>", "Get")

    assert {:error, %UPnP.ParseError{}} = SOAP.parse_fault("<Envelope><Body/></Envelope>")

    assert {:error, %UPnP.ParseError{reason: :invalid_action_name}} =
             SOAP.parse("<Envelope/>", <<0xFF>>)
  end
end
