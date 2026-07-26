# Elixir samples

Run every sample from this `upnp` project after one dependency restore:

```bash
mix deps.get
mix run samples/browser.exs
mix run samples/port_mapper.exs
mix run samples/eventing.exs
mix run samples/dashboard.exs
```

Pass script arguments after the filename; every entry point supports `--help`:

```bash
mix run samples/port_mapper.exs --map
mix run samples/eventing.exs --timeout 900
mix run samples/dashboard.exs --port 4000
```

These are live-network examples. Run them on the host network: SSDP multicast
is commonly unavailable in Docker, WSL, and devcontainers.

The `browser/` directory remains a proper supervised Mix application for
distributed-BEAM introspection.
