defmodule UpnpExplorerWeb.ErrorJSONTest do
  use UpnpExplorerWeb.ConnCase, async: true

  test "renders 404" do
    assert UpnpExplorerWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert UpnpExplorerWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
