defmodule UPnP.IGDModelTest do
  use ExUnit.Case, async: true

  alias UPnP.IGD.Protocol

  test "protocol values have strict output and lenient input" do
    assert Protocol.to_wire(:tcp) == "TCP"
    assert Protocol.to_wire(:udp) == "UDP"
    assert Protocol.parse(" udp ") == {:ok, :udp}
    assert Protocol.parse("sctp") == {:error, :invalid_protocol}
  end
end
