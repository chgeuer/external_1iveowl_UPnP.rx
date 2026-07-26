defmodule Upnp.MixProject do
  use Mix.Project

  def project do
    [
      app: :upnp,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "OTP-native UPnP control point for Elixir",
      source_url: "https://github.com/1iveowl/UPnP.rx",
      package: [
        files: ["lib", "mix.exs", "README.md", "LICENSE", ".formatter.exs"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/1iveowl/UPnP.rx"}
      ],
      docs: [
        main: "UPnP",
        extras: ["README.md", "LICENSE"],
        groups_for_modules: [
          "Control point": [
            UPnP,
            UPnP.ControlPoint,
            UPnP.ControlPoint.Runtime,
            UPnP.DescribedDevice,
            UPnP.Service,
            UPnP.Options,
            UPnP.Network,
            UPnP.Network.System
          ],
          "Internet Gateway Device": [
            UPnP.IGD,
            UPnP.IGD.Gateway,
            UPnP.IGD.Lease,
            UPnP.IGD.Mapping,
            UPnP.IGD.Status
          ],
          Eventing: [
            UPnP.Eventing.Event,
            UPnP.Eventing.Lifecycle
          ],
          "Wire formats": [
            UPnP.Description,
            UPnP.SCPD,
            UPnP.SOAP,
            UPnP.Eventing.PropertySet,
            UPnP.SSDP,
            UPnP.Eventing.AV.LastChange,
            UPnP.SSDP.SearchTarget
          ],
          Testing: [UPnP.Clock.Manual],
          Instrumentation: [UPnP.Telemetry]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {UPnP.Application, []}
    ]
  end

  defp deps do
    [
      {:saxy, "~> 1.6"},
      {:finch, "~> 0.23"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:telemetry, "~> 1.4"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
