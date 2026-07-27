# UPnP Explorer

A Phoenix LiveView observatory and advanced protocol explorer for the UPnP
landscape on a home network. It discovers devices continuously, describes their
capabilities, separates semantic changes from SSDP wire traffic, watches GENA
service events, and inspects Internet Gateway Device state.

## Run it

Run the sample on the host network; SSDP multicast is commonly unavailable in
Docker, WSL, and devcontainers.

```bash
mix setup
just start
```

The command prints the stable URL assigned by `phx-port`; `just port` prints
only its port and `just open` opens it in a browser. The local UPnP package is
loaded through `{:upnp, path: "../.."}`.

## Run it as a desktop app

[ExTauri](https://hex.pm/packages/ex_tauri) wraps the same LiveView application
in a native Tauri window. Install Rust and the
[Tauri platform prerequisites](https://v2.tauri.app/start/prerequisites/), then:

```bash
mix setup
just tauri-setup
just tauri
```

The desktop sidecar starts through `just start`, so it keeps the stable
`phx-port` assignment and remains attachable with `just status`, `just rpc`, and
`just stop`. Stop an existing browser development node before starting Tauri.

Build a platform bundle with `just tauri-build`. ExTauri production wrapping
currently requires OTP 27 and Burrito's Zig toolchain; generated bundles land
under `src-tauri/target/release/bundle/`.

The default UI remains observational, but each service action has an advanced
SCPD-generated executor. Known queries run directly; state-changing, destructive,
and connectivity-risk actions require an explicit second confirmation. These
calls affect real devices and can interrupt network access. Mutation outcomes
are retained in Activity even if the service inspector is closed.

## Distributed development node

`just` is the high-level server interface. Every start also enables distributed
Erlang so the running system can be inspected without restarting:

```bash
just start-bg
just status
just rpc 'Supervisor.which_children(UpnpExplorer.Supervisor)'
just rpc 'UpnpExplorer.Explorer.snapshot()'
just stop
```

Use `just eval-file path/to/check.exs` for multi-line inspection. The
lower-level `scripts/dev_node.sh` wrapper remains available for direct
`await`, `rpc`, and `eval_file` operations.

See [`docs/design.md`](docs/design.md) for the product, interaction, visual, and
runtime design.
