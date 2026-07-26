# UPnP

An OTP-native UPnP control point for Elixir: discover devices with SSDP, parse
device and service descriptions, invoke SOAP actions, subscribe to GENA events,
and manage Internet Gateway Device (IGD) port mappings.

The library does not reproduce Reactive Extensions. Immutable protocol values
flow through ordinary functions, while stateful network lifecycles run as
monitored, supervised OTP processes.

## Features

- SSDP discovery and passive alive/byebye handling on every usable IPv4
  interface
- Atomic roster snapshots plus monitored live subscriptions
- Lenient DDD and SCPD parsing with absolute URL resolution
- Strict SOAP 1.1 composition, bounded HTTP responses, and UPnP fault parsing
- Boot/config-aware single-flight description and SCPD caches
- Typed IGD gateway actions, mapping enumeration, and renewable mapping leases
- Shared GENA subscriptions, lazy Bandit callback listener, renewal, replay,
  early-NOTIFY handling, and 32-bit sequence-gap recovery
- UPnP AV `LastChange` parsing
- Injectable HTTP, UDP, GENA, network-route, and clock boundaries
- Telemetry events for protocol failures and lifecycle transitions

## Installation

Add `upnp` to `mix.exs`:

```elixir
def deps do
  [
    {:upnp, "~> 0.1.0"}
  ]
end
```

Start a control point under your application's supervisor:

```elixir
children = [
  {UPnP.ControlPoint, name: MyApp.UPnP}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Each control point runs as an isolated OTP runtime: starting one starts a
`UPnP.ControlPoint.Runtime` supervisor that owns that control point's
coordinator, its SSDP interface workers, its GENA processes, and its tasks. One
control point can therefore neither restart nor outlive another, and a crash
inside one is invisible to the rest. The started pid, the `:name` above, and the
coordinator pid are interchangeable handles. Only the HTTP pool, the process
registry, the runtime roots, and IGD leases are shared application-wide.

`interfaces: :auto` selects all up, multicast-capable, non-loopback IPv4
interfaces. Pass an explicit list such as `interfaces: [{192, 168, 1, 20}]` to
limit discovery.

Route selection for both GENA callback URLs and IGD internal clients uses the
configured `UPnP.Network` Adapter. `network_adapter` accepts either a module or
`{module, state}` and defaults to `UPnP.Network.System`, which asks the kernel
which local IPv4 address faces the remote URL:

```elixir
{UPnP.ControlPoint,
 name: MyApp.UPnP,
 network_adapter: {MyApp.RouteAdapter, route_state}}
```

### Samples

Runnable `.exs` equivalents of every .NET sample live in
[`samples`](https://github.com/1iveowl/UPnP.rx/tree/main/upnp/samples):

```bash
mix run samples/browser.exs
mix run samples/port_mapper.exs --map
mix run samples/eventing.exs
mix run samples/dashboard.exs
```

They cover live device browsing, IGD state and renewable mappings, GENA
subscriptions, and a Bandit/Plug network dashboard. The
[`samples/upnp_explorer`](samples/upnp_explorer) Phoenix LiveView application
adds a polished, read-only device, activity, service-event, and gateway
observatory. Run samples on the host network; multicast is commonly unavailable
in containers. The supervised `samples/browser` Mix application remains
available for distributed-BEAM introspection.

## Discover, describe, and control

```elixir
alias UPnP.{ControlPoint, DescribedDevice, Service}
alias UPnP.SSDP.SearchTarget

{:ok, devices} =
  ControlPoint.discover(
    MyApp.UPnP,
    target: SearchTarget.root_device(),
    mx: 3
  )

[device | _] = devices
{:ok, described} = ControlPoint.describe(MyApp.UPnP, device)

{:ok, service} =
  DescribedDevice.service(
    described,
    "urn:schemas-upnp-org:service:ContentDirectory:1"
  )

{:ok, result} = Service.invoke(service, "GetSystemUpdateID")
update_id = UPnP.ActionResult.get(result, "Id")
```

`Service.invoke/4` checks actions and input arguments against the cached SCPD
and emits arguments in declaration order. For a device with a known-broken
SCPD, `validate: false` bypasses that check without weakening SOAP escaping:

```elixir
Service.invoke(service, "VendorAction", [{"Input", "value"}], validate: false)
```

All network and protocol failures are tagged values. A SOAP fault is returned
as `{:error, {:upnp_error, %UPnP.UpnpError{}}}`.

### Live roster

```elixir
{:ok, subscription, current_devices} =
  ControlPoint.subscribe_roster(MyApp.UPnP)

receive do
  {:upnp, ^subscription.ref, %UPnP.Roster.Event{} = event} ->
    IO.inspect(event)
end

UPnP.Subscription.close(subscription)
```

The snapshot and subscription are installed atomically, so no roster change is
lost between them.

## Internet Gateway Devices

```elixir
alias UPnP.IGD
alias UPnP.IGD.{Gateway, Lease}

{:ok, gateway} = IGD.discover_gateway(MyApp.UPnP, mx: 3)

if gateway do
  {:ok, external_address} = Gateway.external_address(gateway)

  {:ok, lease} =
    Gateway.add_port_mapping(
      gateway,
      8080,
      8080,
      :tcp,
      description: "my service",
      lease_duration: 3600
    )

  {:ok, lifecycle} = Lease.subscribe(lease)

  receive do
    {:upnp, ^lifecycle.ref, %UPnP.IGD.LeaseEvent{} = event} ->
      IO.inspect(event)
  after
    1000 -> :ok
  end

  :ok = Lease.close(lease)
end
```

Finite mappings renew at half-life. Renewal failures are lifecycle data and
keep retrying; an `:expired` event is emitted after failures outlive the lease.
`Lease.close/1` is graceful and deletes the mapping. `Lease.abandon/1` and
owner-process loss are abrupt: renewal stops, no network delete is sent, and a
finite mapping expires on the gateway. A zero-duration lease is indefinite and
intentionally opts out of both renewal and expiry protection.

The default internal client is the local address the kernel routes toward the
gateway's SOAP control URL. This remains correct with multiple LAN, VPN, and
container interfaces and satisfies gateway secure modes that require the
mapping target to match the requesting client.

The lease owner defaults to the process calling `add_port_mapping`. If the call
runs in a short-lived task, pass a stable `owner: pid`.

## GENA eventing

```elixir
{:ok, subscription, current_properties} = Service.subscribe(service)

receive do
  {:upnp, ^subscription.ref, %UPnP.Eventing.Event{} = event} ->
    IO.inspect(event.properties)

  {:upnp, ^subscription.ref, %UPnP.Eventing.Lifecycle{} = lifecycle} ->
    IO.inspect(lifecycle)
end

UPnP.Subscription.close(subscription)
```

Local consumers of the same canonical event URL share one remote subscription.
Late consumers receive the current property snapshot atomically. The final
local close sends `UNSUBSCRIBE`; abrupt control-point loss sends no goodbye.

The callback listener starts only when the first event subscription is opened.
By default it binds an ephemeral port on all addresses and asks the routing
table which local address faces the device. For containers, NAT, or a fixed
firewall rule, configure an address the device can reach:

```elixir
{UPnP.ControlPoint,
 name: MyApp.UPnP,
 event_callback_bind: {0, 0, 0, 0},
 event_callback_port: 4001,
 event_callback_base_url: "http://192.168.1.20:4001"}
```

Callback paths contain independent cryptographically random manager and
subscription tokens. The endpoint accepts only bounded `NOTIFY` requests with
valid GENA headers and XML content types.

For AV services, decode a `LastChange` property's value separately:

```elixir
{:ok, changes} = UPnP.Eventing.AV.LastChange.parse(last_change.value)
```

## Pure wire APIs

The parsers and composers perform no I/O and return tagged results. These are
the canonical public entry points:

| Wire format | Canonical interface |
| --- | --- |
| Device description | `UPnP.Description.parse/2` |
| SCPD | `UPnP.SCPD.parse/1` |
| SOAP | `UPnP.SOAP.compose/3`, `soap_action_header/2`, `parse/2`, `parse_fault/1` |
| GENA property set | `UPnP.Eventing.PropertySet.parse/1` |
| SSDP | `UPnP.SSDP.parse/1`, `m_search/2` |
| AV LastChange | `UPnP.Eventing.AV.LastChange.parse/1` |

```elixir
UPnP.Description.parse(device_xml, location)
UPnP.SCPD.parse(scpd_xml)
UPnP.SOAP.compose(service_type, action, arguments)
UPnP.SOAP.parse(response_xml, action)
UPnP.Eventing.PropertySet.parse(property_set_xml)
UPnP.SSDP.parse(ssdp_datagram)
UPnP.SSDP.m_search(search_target, options)
UPnP.Eventing.AV.LastChange.parse(last_change_xml)
```

Parsing is strict only when a document cannot be identified. Unknown extension
elements and malformed optional fields are ignored or left unset.

## Lifecycles and time

- `UPnP.ControlPoint.close/2` gracefully closes GENA subscriptions and returns
  once the control point's runtime and everything it owns are gone.
- `UPnP.stop_control_point/1` is abrupt and performs no protocol goodbyes.
- `UPnP.IGD.Lease.close/1` deletes a mapping; `Lease.abandon/1` does not.
- Subscriber and owner processes are monitored; explicit handles remain
  available for deterministic cleanup.

All protocol timers and UTC event timestamps use the configured `UPnP.Clock`.
Tests can use one manually advanced clock:

```elixir
{:ok, clock} = UPnP.Clock.Manual.start_link()

{:ok, control_point} =
  UPnP.ControlPoint.start_link(
    interfaces: [],
    clock: {UPnP.Clock.Manual, clock}
  )

:ok = UPnP.Clock.Manual.advance(clock, 1000)
```

## Telemetry

`UPnP.Telemetry.events/0` lists every event name. Events cover SSDP errors and
drops, roster changes, description fetches, SOAP actions, GENA notifications
and lifecycle transitions, and IGD lease transitions. Every event includes a
`:count` measurement; metadata contains protocol identifiers and sanitized
outcomes, never response bodies.

## Dependencies

| Package | Purpose |
| --- | --- |
| `saxy` | Total XML parsing and strict XML generation |
| `finch` | Bounded outgoing HTTP, including custom GENA verbs |
| `bandit` + `plug` | Lazy inbound GENA callback listener |
| `telemetry` | Runtime instrumentation |
| `stream_data` | Property tests in the test environment |

SSDP uses Erlang's built-in `:gen_udp`; no SSDP package is required. Multicast
is commonly unavailable inside devcontainers, so automated tests inject the
UDP boundary and never require a real LAN. Hardware interoperability should be
smoke-tested on the target network.

## License

MIT License. See [LICENSE](LICENSE).
