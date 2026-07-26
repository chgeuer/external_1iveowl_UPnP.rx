defmodule UPnP.NetworkTest do
  use ExUnit.Case, async: true

  test "asks the kernel which local IPv4 address faces a URI" do
    assert {:ok, {127, 0, 0, 1}} =
             UPnP.Network.local_address_for(URI.parse("http://127.0.0.1/device.xml"))
  end

  test "rejects URIs without a routable host" do
    assert {:error, :missing_host} = UPnP.Network.local_address_for(URI.parse("/relative"))
  end
end
