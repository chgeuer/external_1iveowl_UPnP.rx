defmodule UPnP.XMLTest do
  use ExUnit.Case, async: true

  test "Saxy simple-form names and attributes remain binaries" do
    assert {:ok, {name, attributes, _content}} =
             UPnP.XML.parse(~s(<wire:Root xmlns:wire="urn:test" Wire:Value="x"/>))

    assert is_binary(name)

    assert Enum.all?(attributes, fn {attribute_name, value} ->
             is_binary(attribute_name) and is_binary(value)
           end)
  end
end
