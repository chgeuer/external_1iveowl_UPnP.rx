defmodule UpnpBrowser.MixProject do
  use Mix.Project

  def project do
    [
      app: :upnp_browser,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: ["lib", Path.expand("../support", __DIR__)],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [browser: "run --no-halt"]
    ]
  end

  def application do
    application = [extra_applications: [:logger]]

    if Mix.env() == :test do
      application
    else
      Keyword.put(application, :mod, {UPnPBrowser.Application, []})
    end
  end

  defp deps do
    [
      {:upnp, path: "../.."}
    ]
  end
end
