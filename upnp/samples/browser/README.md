# UPnP Browser

Discovers every UPnP root device on the local network, fetches its description,
and prints the device tree and services using the same layout as the .NET
`Sample.Browser`.

Run it on the host rather than in Docker, WSL, or a devcontainer:

```bash
mix deps.get
mix browser
```

Press Enter to stop gracefully. For a non-interactive process that remains
available for distributed-BEAM inspection:

```bash
UPNP_BROWSER_NO_INPUT=1 scripts/dev_node.sh start
scripts/dev_node.sh rpc "UPnPBrowser.Browser.snapshot()"
scripts/dev_node.sh stop
```
