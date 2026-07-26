# UPnP Explorer

A read-only Phoenix LiveView observatory for the UPnP landscape on a home
network. It discovers devices continuously, describes their capabilities,
separates semantic changes from SSDP wire traffic, watches GENA service events,
and inspects Internet Gateway Device state.

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

The default UI is intentionally observational. It only invokes explicitly
allowlisted read-only queries such as `GetExternalIPAddress`; it does not expose
generic SOAP actions or create and delete router mappings.

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
