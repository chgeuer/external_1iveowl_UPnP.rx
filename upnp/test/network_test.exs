defmodule UPnP.NetworkTest do
  use ExUnit.Case, async: true

  alias UPnP.Network

  defmodule FakeAdapter do
    @behaviour UPnP.Network

    @impl true
    def local_address_for(uri, {test, result}) do
      send(test, {:route_requested, uri})
      result
    end
  end

  test "dispatches route selection through the configured Adapter and state" do
    uri = URI.parse("http://192.0.2.10/device.xml")
    adapter = {FakeAdapter, {self(), {:ok, {192, 0, 2, 20}}}}

    assert {:ok, {192, 0, 2, 20}} = Network.local_address_for(adapter, uri)
    assert_receive {:route_requested, ^uri}
  end

  test "rejects URIs without a routable host" do
    assert {:error, :missing_host} =
             Network.local_address_for(UPnP.Network.System, URI.parse("/relative"))
  end
end
