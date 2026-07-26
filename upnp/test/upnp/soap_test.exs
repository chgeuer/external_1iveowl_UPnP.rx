defmodule UPnP.SOAPTest do
  use ExUnit.Case, async: true

  alias UPnP.SOAP.{Composer, Parser}

  test "composer emits the exact SOAP 1.1 envelope and escapes values" do
    assert {:ok, body} =
             Composer.compose_action_request(
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
             Composer.soap_action_header(
               "urn:schemas-upnp-org:service:WANIPConnection:2",
               "AddPortMapping"
             )
  end

  test "composer rejects invalid names as parse errors" do
    assert {:error, %UPnP.ParseError{source: :soap_request}} =
             Composer.compose_action_request("urn:service", "Bad Action", [])

    assert {:error, %UPnP.ParseError{}} =
             Composer.compose_action_request("urn:service", "Action", [{"Bad Name", "x"}])

    assert {:error, %UPnP.ParseError{reason: :invalid_argument_value}} =
             Composer.compose_action_request("urn:service", "Action", [{"Value", <<0>>}])

    assert {:error, %UPnP.ParseError{}} =
             Composer.compose_action_request("urn:service", "Action", [{<<0xFF>>, "x"}])
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

    assert {:ok, result} = Parser.parse_action_response(xml, "GetStatusInfo")
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

    assert {:ok, error} = Parser.parse_fault(xml)
    assert error.code == 718
    assert error.description == "ConflictInMappingEntry"
    assert {:ok, {:upnp_error, ^error}} = Parser.parse(xml, "AddPortMapping")
  end

  test "malformed and unidentified SOAP bodies fail without raising" do
    assert {:error, %UPnP.ParseError{}} = Parser.parse_action_response("not XML", "Get")

    assert {:error, %UPnP.ParseError{reason: :missing_action_response}} =
             Parser.parse_action_response("<Envelope><Body/></Envelope>", "Get")

    assert {:error, %UPnP.ParseError{}} = Parser.parse_fault("<Envelope><Body/></Envelope>")

    assert {:error, %UPnP.ParseError{reason: :invalid_action_name}} =
             Parser.parse_action_response("<Envelope/>", <<0xFF>>)
  end
end
