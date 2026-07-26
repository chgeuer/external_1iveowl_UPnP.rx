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

  test "public helpers are total over optional, malformed, and mixed content" do
    element =
      {"root", [{"Count", "invalid"}, {:ignored, :entry}],
       [
         "prefix",
         {:cdata, " cdata "},
         {"child", [{"value", " 42 "}], ["  12 ", {:other, :ignored}]},
         :ignored
       ]}

    assert UPnP.XML.children(element, "child") == [
             {"child", [{"value", " 42 "}], ["  12 ", {:other, :ignored}]}
           ]

    assert UPnP.XML.descendants(element) == [
             {"child", [{"value", " 42 "}], ["  12 ", {:other, :ignored}]}
           ]

    assert UPnP.XML.attribute(element, "count") == "invalid"
    assert UPnP.XML.attribute(element, "missing") == nil
    assert UPnP.XML.text(element) == "prefix cdata   12 "
    assert UPnP.XML.text_or_nil({"empty", [], ["  "]}) == nil
    assert UPnP.XML.child_token(element, "child") == "12"
    assert UPnP.XML.child_integer(element, "child") == 12
    assert UPnP.XML.child_integer({"root", [], []}, "child") == nil
    assert UPnP.XML.attribute_integer(element, "count") == nil
    assert UPnP.XML.attribute_integer({"root", [], []}, "count") == nil
    assert UPnP.XML.resolve_url(URI.parse("http://device/root.xml"), nil) == nil
    assert UPnP.XML.absolute_http_uri("http://[") == nil
    assert UPnP.XML.resolve_url(URI.parse("http://device/root.xml"), "http://[") == nil
  end

  test "parse errors remain inspectable data" do
    error = %UPnP.ParseError{source: :test, reason: :invalid}
    assert Exception.message(error) == "unable to parse UPnP wire data"
  end
end
