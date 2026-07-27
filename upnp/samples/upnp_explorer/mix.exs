defmodule UpnpExplorer.MixProject do
  use Mix.Project

  def project do
    [
      app: :upnp_explorer,
      version: "0.1.0",
      elixir: ">= 1.19.3 and < 2.0.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {UpnpExplorer.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ex_tauri, "~> 0.2.0"},
      {:upnp, path: "../.."}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind upnp_explorer", "esbuild upnp_explorer"],
      "assets.deploy": [
        "tailwind upnp_explorer --minify",
        "esbuild upnp_explorer --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp releases do
    [
      desktop: [
        steps: [&build_desktop_assets/1, :assemble, &wrap_desktop/1],
        burrito: [targets: [desktop_target()]]
      ]
    ]
  end

  defp build_desktop_assets(release) do
    Mix.Task.run("assets.deploy")
    release
  end

  defp wrap_desktop(release) do
    if System.get_env("BURRITO_SKIP") == "true" do
      release
    else
      Burrito.wrap(release)
    end
  end

  defp desktop_target do
    case {:os.type(), desktop_cpu()} do
      {{:unix, :linux}, :x86_64} ->
        {:"x86_64-unknown-linux-gnu", [os: :linux, cpu: :x86_64]}

      {{:unix, :linux}, :aarch64} ->
        {:"aarch64-unknown-linux-gnu", [os: :linux, cpu: :aarch64]}

      {{:unix, :darwin}, :x86_64} ->
        {:"x86_64-apple-darwin", [os: :darwin, cpu: :x86_64]}

      {{:unix, :darwin}, :aarch64} ->
        {:"aarch64-apple-darwin", [os: :darwin, cpu: :aarch64]}

      {{:win32, _name}, :x86_64} ->
        {:"x86_64-pc-windows-msvc", [os: :windows, cpu: :x86_64]}

      {{:win32, _name}, :aarch64} ->
        {:"aarch64-pc-windows-msvc", [os: :windows, cpu: :aarch64]}

      platform ->
        raise "unsupported ExTauri build platform: #{inspect(platform)}"
    end
  end

  defp desktop_cpu do
    :erlang.system_info(:system_architecture)
    |> to_string()
    |> String.split("-", parts: 2)
    |> hd()
    |> case do
      "x86_64" -> :x86_64
      "aarch64" -> :aarch64
      "arm64" -> :aarch64
      architecture -> architecture
    end
  end
end
