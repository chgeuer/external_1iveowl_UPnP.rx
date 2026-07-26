defmodule UPnP.SCPD.ParserTest do
  use ExUnit.Case, async: true

  alias UPnP.SCPD.Parser

  test "parses actions, arguments, state variables, values, and ranges" do
    xml = """
    <s:SCPD xmlns:s="urn:schemas-upnp-org:service-1-0">
      <s:specVersion><s:major>1</s:major><s:minor>0</s:minor></s:specVersion>
      <s:actionList>
        <s:ACTION>
          <s:name>GetStatusInfo</s:name>
          <s:argumentList>
            <s:argument>
              <s:name>NewConnectionStatus</s:name>
              <s:direction>OUT</s:direction>
              <s:retval/>
              <s:relatedStateVariable>ConnectionStatus</s:relatedStateVariable>
            </s:argument>
            <s:argument>
              <s:name>NewRemoteHost</s:name>
              <s:direction>in</s:direction>
              <s:relatedStateVariable>RemoteHost</s:relatedStateVariable>
            </s:argument>
          </s:argumentList>
        </s:ACTION>
      </s:actionList>
      <s:serviceStateTable>
        <s:stateVariable SendEvents="NO">
          <s:name>ConnectionStatus</s:name>
          <s:dataType>string</s:dataType>
          <s:defaultValue>Unconfigured</s:defaultValue>
          <s:allowedValueList>
            <s:allowedValue>Connected</s:allowedValue>
            <s:allowedValue>A & B</s:allowedValue>
            <s:allowedValue> </s:allowedValue>
          </s:allowedValueList>
        </s:stateVariable>
        <s:stateVariable>
          <s:name>Port</s:name>
          <s:dataType>ui2</s:dataType>
          <s:allowedValueRange>
            <s:minimum>0</s:minimum>
            <s:maximum>65535</s:maximum>
            <s:step>1</s:step>
          </s:allowedValueRange>
        </s:stateVariable>
      </s:serviceStateTable>
      <vendorExtension>ignored</vendorExtension>
    </s:SCPD>
    """

    assert {:ok, scpd} = Parser.parse(xml)
    assert scpd.spec_version.major == 1
    assert [action] = scpd.actions
    assert action.name == "GetStatusInfo"
    assert [result_argument, input_argument] = action.arguments
    assert result_argument.direction == :out
    assert result_argument.is_return_value
    assert input_argument.direction == :in

    assert [status, port] = scpd.state_variables
    refute status.sends_events
    assert status.default_value == "Unconfigured"
    assert status.allowed_values == ["Connected", "A & B"]
    assert port.sends_events
    assert port.allowed_range.minimum == "0"
    assert port.allowed_range.maximum == "65535"
    assert port.allowed_range.step == "1"
  end

  test "retains malformed declarations with nil and unknown optional values" do
    xml = """
    <scpd>
      <actionList>
        <action><argumentList><argument><direction>sideways</direction></argument></argumentList></action>
      </actionList>
      <serviceStateTable><stateVariable sendEvents="maybe"><dataType/></stateVariable></serviceStateTable>
    </scpd>
    """

    assert {:ok, scpd} = Parser.parse(xml)
    assert [%{name: nil, arguments: [%{direction: :unknown}]}] = scpd.actions
    assert [%{name: nil, data_type: nil, sends_events: true}] = scpd.state_variables
  end

  test "empty SCPD is valid while malformed XML returns data error" do
    assert {:ok, %{actions: [], state_variables: []}} = Parser.parse("<scpd/>")
    assert {:error, %UPnP.ParseError{source: :scpd}} = Parser.parse("<scpd>")
  end
end
