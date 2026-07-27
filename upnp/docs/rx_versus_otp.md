# The same UPnP control point in .NET Rx and Elixir OTP

## A friendly tour for an Rx developer who has never met the BEAM

Jasper (`1iveowl`) built UPnP.Rx around a strong idea: UPnP is not a sequence of isolated HTTP calls. It is a collection of event streams and long-lived lifecycles.

Devices appear, refresh their presence, reboot, and disappear. Description documents are fetched and cached. GENA subscriptions renew, receive callbacks, detect sequence gaps, and eventually say goodbye. Port mappings live for a while, renew at half-life, and need different graceful and abrupt shutdown paths.

Reactive Extensions is a very natural way to model that in .NET. So what happens when the same workload moves to Elixir, where the runtime already gives us lightweight processes, mailboxes, monitors, and supervision?

The interesting answer is not "OTP replaces every `IObservable<T>` with a
GenServer." It is subtler:

> The protocol rules stay almost exactly the same, but the concurrency model moves from a graph of streams and disposables to a topology of communicating processes.

This is not an argument that Rx was the wrong choice. UPnP.Rx is precisely what makes the comparison useful: it is a careful, modern Rx design with explicit temperature, cancellation, failure, time, and disposal policies. The Elixir version is less a rewrite of bad code than a translation between two excellent ways of thinking about asynchronous systems.

## The 30-second comparison

| Concern | .NET with Rx | Elixir with OTP |
|---|---|---|
| Immutable data | Records | Structs |
| Live updates | `IObservable<T>` notifications | Messages sent to subscriber processes |
| Stateful engine | Object, collections, locks, tasks | A process owning state behind a mailbox |
| Fan-out | Rx operators and observers | The owner process sends a message to each subscriber |
| Async I/O | `Task`, `SelectMany`, `FromAsync` | Supervised tasks report results back to an owning process |
| Shared source | `Publish`/`RefCount` or a custom shared `IObservable<T>` | One manager process tracks consumers and owns one worker |
| Replay | Emit remembered values under the same gate as live events | Return snapshot and install subscription in one serialized call |
| Lifetime | `IDisposable`, `IAsyncDisposable`, cancellation tokens | Explicit handles, process monitors, and process termination |
| Expected failure | Typed value or ordinary exception at the async edge | Tagged result such as `{:error, reason}` or a lifecycle message |
| Unexpected engine death | `OnError`, logging, owner cleanup | Process exit observed by a supervisor or monitor |
| Testable time | `TimeProvider` | `UPnP.Clock` behavior with a manual clock |
| Runtime inspection | Debugger, logs, metrics | Those, plus process trees, mailboxes, and live state inspection |

That table is useful, but it can also be misleading. OTP is not an Rx library
with different names. To see why it feels different, we need to start with the
unit of concurrency.

## Elixir, the BEAM, and OTP are three different things

The names often arrive as one bundle, so a quick separation helps:

- **Elixir** is the language: its syntax, modules, protocols, macros, structs,
  and functional standard library.
- **The BEAM** is the virtual machine: it schedules processes, moves messages,
  manages memory, and supports distributed nodes and live introspection.
- **OTP** is the standard library and set of design patterns for building
  reliable applications on that runtime.

OTP originally stood for Open Telecom Platform, but today the initials are mostly treated as a proper name. Its familiar pieces include `GenServer`, `Supervisor`, `DynamicSupervisor`, `Registry`, and `Task.Supervisor`. They are not an optional actor framework layered on top of Elixir; they are the normal vocabulary used to give concurrent work ownership and recovery rules.

## A BEAM process is a small, isolated owner

An Elixir process is not an operating-system process and it is not one thread. It is a lightweight actor scheduled by the BEAM virtual machine. It has:

- a private heap,
- a mailbox,
- a process identifier,
- links and monitors to other processes, and
- no shared mutable state with its neighbors.

A `GenServer` is a standard pattern for turning such a process into a
request/message loop. Despite the name, it does not mean "web server." It means
"a process that owns some state and handles a protocol."

That ownership is the first big shift for an Rx developer.

In the .NET roster engine, a reentrant lock protects the observer list, current
entries, replay, and emissions. The lock is load-bearing because callbacks and
inline continuations can re-enter the engine. In Elixir, the control-point
process owns the roster map. Calls and incoming SSDP messages enter one mailbox
and are handled serially. There is no lock around that map because no other
process can touch it.

This does not make races disappear from the whole system. It moves them to
explicit boundaries between processes, where messages, references, monitors,
and ownership rules make them easier to see.

## Discovery: a pipeline versus a protocol process

The .NET discovery path is beautifully Rx-shaped:

1. `Observable.Defer` keeps construction side-effect free.
2. M-SEARCH responses and `ssdp:alive` notifications are projected into
   `DiscoveredDevice` values.
3. `Merge` combines the sources.
4. `Distinct` suppresses duplicate device/boot identities.
5. `Observable.Create` subscribes before sending M-SEARCH, so a fast response
   cannot outrun the observer.
6. Disposal cancels in-flight work and releases the shared upstream source.

The public temperature is part of the contract: `DiscoverDevices()` is cold,
while the roster becomes hot and shared for as long as it has subscribers.

The Elixir control point chooses a more service-like lifetime. Once started
under a supervisor, a stable lifecycle owner manages replaceable
`UPnP.ControlPoint.Runtime` generations. Each generation owns everything that
belongs to that one control point, and its coordinator process coordinates:

- one UDP worker per configured IPv4 interface,
- the current presence roster and expiry timers,
- description and SCPD caches,
- pending single-flight fetches,
- local subscribers, and
- the GENA manager associated with that control point.

Each UDP worker parses a datagram and sends an envelope to the control point.
The control point updates its state and broadcasts a typed roster event. Slow
description fetches and SOAP calls do not block its mailbox; they run in the
runtime's own `Task.Supervisor` and return a tagged result to the coordinator.
Because that whole subtree is owned rather than shared, a failure inside one
control point cannot restart or outlive another. Five immediate generation
restarts are allowed in ten seconds. Exhaustion leaves the stable public owner
registered while it retries with clock-driven delays of 1, 2, 4, 8, 16, then
at most 30 seconds; sixty healthy seconds reset that backoff. Calls during the
gap return tagged `{:error, :control_point_restarting}` data rather than waiting
or accidentally addressing a supervisor. A mutually monitored reaper exists
outside that owner just long enough to remove a partially started generation if
an untrappable owner exit prevents its normal teardown callback from running.
It mirrors the bounded subscription index so terminal lifecycle data is not
lost with the owner.

The API reflects that difference:

```csharp
using var subscription = client.Roster().Subscribe(change =>
    Console.WriteLine(change));
```

```elixir
{:ok, subscription, current_devices} =
  UPnP.ControlPoint.subscribe_roster(MyApp.UPnP)

subscription_ref = subscription.ref

receive do
  {:upnp, ^subscription_ref, %UPnP.Roster.Event{} = event} ->
    IO.inspect(event)
end

UPnP.Subscription.close(subscription)
```

The Elixir call returns the snapshot and installs the live subscription as one
mailbox operation. That makes the "snapshot, then events" handoff atomic. The
reference in each message prevents unrelated subscriptions in the same process
from being confused with one another.

There is another small but important OTP touch: the control point monitors the
subscriber. If the subscriber process dies, a `:DOWN` message arrives and its
subscription is removed. Cleanup does not depend solely on application code
remembering to dispose a handle.

## GENA is where the process model really clicks

GENA eventing has enough moving parts to expose the character of both designs.

The .NET `GenaSubscriptionSource` is one shared source per event URL. It keeps:

- a gated list of observers,
- a last-known property dictionary for replay,
- a cancellation token source,
- one engine task,
- renewal and retry loops, and
- an in-process callback route.

The first observer starts the remote subscription. Late observers receive
replay under the same gate used for live emissions. The last disposal cancels
the engine, whose own asynchronous teardown sends `UNSUBSCRIBE`. This is careful
Rx engineering: serialized grammar, no fire-and-forget async disposal, and one
remote subscription for N local observers.

The OTP implementation preserves those semantics almost one for one, but gives
the roles names in the process tree:

- an eventing manager owns the callback server and the local consumer index,
- one subscription worker owns each canonical event URL,
- the Bandit callback server starts lazily on first use,
- each worker owns its SID, sequence expectation, property snapshot, renewal
  timer, and retry state, and
- monitors tell the manager when consumers or workers disappear.

The first local consumer creates the worker. Further consumers attach to it and
receive the current property snapshot. When the final consumer closes, the
worker performs `UNSUBSCRIBE` and exits.

From the caller's perspective:

```csharp
using var events = service.Events().Subscribe(
    value => Console.WriteLine(value),
    error => Console.Error.WriteLine(error));
```

becomes:

```elixir
{:ok, subscription, current_properties} =
  UPnP.Service.subscribe(service)

subscription_ref = subscription.ref

receive do
  {:upnp, ^subscription_ref, %UPnP.Eventing.Event{} = event} ->
    IO.inspect(event.properties)

  {:upnp, ^subscription_ref, %UPnP.Eventing.Lifecycle{} = lifecycle} ->
    IO.inspect(lifecycle)
end

UPnP.Subscription.close(subscription)
```

The Elixir `receive` is selective pattern matching over a mailbox. It is not a
busy loop and it does not reserve a thread while waiting.

What Rx represents as a shared stream with internal state, OTP represents as a
small service with an address and a lifecycle. Neither is inherently more
correct. The OTP version simply makes the remote subscription's identity feel
very literal: there is a process for it.

## A port-mapping lease tells the whole story

The auto-renewing IGD lease is perhaps the cleanest side-by-side example.

In .NET, `PortMappingLease` contains a cancellation token source, a synchronized
subject, a periodic timer loop, an interlocked disposal flag, and the gateway
used to renew or delete the mapping. It exposes lifecycle outcomes as a hot
observable. `DisposeAsync` is graceful and deletes the mapping; synchronous
`Dispose` is abrupt and lets the finite lease expire.

In Elixir, every lease is a temporary supervised worker. Its state contains:

- the mapping and gateway,
- the clock and renewal timer,
- the current renewal task,
- the last successful renewal time,
- lifecycle subscribers, and
- a monitor on the process that owns the lease.

Renewal is still scheduled at half-life. A failed renewal is still data, not
engine death. Graceful `Lease.close/1` still deletes the mapping, while
`Lease.abandon/1` stops renewal without a network goodbye.

The novel part is owner monitoring. If the process that created the lease
crashes, the worker receives `:DOWN`, cancels renewal, and exits abruptly. The
router's finite lease remains the final safety net.

This is an important correction to the usual "let it crash" slogan. OTP does
not magically perform protocol cleanup for us, and garbage collection is not a
network lifecycle. The design still distinguishes graceful and abrupt
termination. OTP contributes a reliable signal that an owner vanished and a
standard place to react to it.

## "Let it crash" does not mean "crash on bad packets"

Someone encountering OTP for the first time can reasonably hear "let it crash"
and imagine a system that turns every timeout or malformed XML document into a
restart.

That is not what this implementation does.

Expected network and protocol failures are values:

```elixir
{:ok, described_device}
{:error, :missing_scpd_url}
{:error, {:upnp_error, %UPnP.UpnpError{code: 606}}}
```

Renewal failures and sequence gaps are lifecycle messages. A malformed optional
field is ignored or left unset. Per-device description failure does not kill
discovery.

A process crash is reserved for something structurally different: a violated
invariant, an unexpected dependency failure, or a bug that means this engine
can no longer be trusted. A supervisor can then restart the isolated component
without pretending that an ordinary router timeout is exceptional.

That is very close to UPnP.Rx's own rule:

> Per-item failure is data; stream failure is source death.

Rx expresses source death as `OnError`. OTP expresses it as process exit. The
philosophy is shared even though the runtime mechanism differs.

## The pure core barely changes

The least dramatic part of the port is also reassuring.

Both implementations keep wire parsing and composition separate from runtime
lifecycles:

- device descriptions and SCPDs become immutable values,
- SOAP composition is strict,
- parsing is lenient about real devices,
- optional nonsense stays optional,
- a document fails only when it cannot identify what it claims to describe,
  and
- parsers perform no network I/O, logging, timing, or hidden mutation.

.NET returns `ParseResult<T>` and immutable records. Elixir returns
`{:ok, value}` or `{:error, %ParseError{}}` and immutable structs.

This is worth emphasizing because "use a GenServer" is often bad Elixir advice.
A parser has no lifecycle and owns no changing state, so it should be an
ordinary function. OTP is for the stateful edge, not a replacement for
functional programming.

The transport building blocks naturally differ by ecosystem. UPnP.Rx reuses
`SSDP.UPnP.PCL`, `SimpleHttpListener.Rx`, and `System.Reactive`. The Elixir
version uses Erlang's built-in `:gen_udp` for SSDP, Saxy for XML, Finch for
outgoing HTTP, Bandit and Plug for inbound GENA callbacks, and Telemetry for
instrumentation. Those choices change the amount of wire-level code each
version owns, but they do not dictate the Rx-versus-OTP architecture.

## Time and testing: surprisingly similar

The two versions are unusually aligned on time.

UPnP.Rx has one `TimeProvider`. Timers, expiry, retries, and renewals use it, and
tests advance a fake provider. Time-based Rx operators are not allowed to
smuggle in a second wall clock.

The Elixir version has one `UPnP.Clock` boundary. Production uses the system
clock; tests use `UPnP.Clock.Manual` and advance it explicitly.

The network seams are parallel too:

| .NET seam | Elixir seam |
|---|---|
| `IControlPoint` driven by a test `Subject` | Injectable SSDP transport or direct envelope injection |
| Fake `HttpMessageHandler` | HTTP behavior with a fake adapter |
| `TimeProvider` | `UPnP.Clock` |
| `IGenaTransport` | Eventing transport behavior |
| Observable subscriptions | Monitored message subscriptions |

Neither suite needs multicast. Both can test renewal, expiry, replay, faults,
and teardown deterministically.

The BEAM adds a pleasant debugging bonus. A running sample can be queried
without adding a temporary diagnostics endpoint:

```bash
cd upnp/samples/browser
UPNP_BROWSER_NO_INPUT=1 scripts/dev_node.sh start
scripts/dev_node.sh rpc "Supervisor.which_children(UPnPBrowser.Supervisor)"
scripts/dev_node.sh rpc "UPnPBrowser.Browser.snapshot()"
scripts/dev_node.sh stop
```

You can also inspect a GenServer with `:sys.get_state/1`, inspect mailbox length
with `Process.info/2`, or walk a supervision tree. It feels a little like having
a debugger designed into the runtime's operating model.

## A rough Rx-to-OTP phrasebook

These are analogies, not mechanical substitutions:

| Familiar Rx idea | Closest OTP-shaped idea here |
|---|---|
| Cold observable | A function call that starts work for this caller |
| Hot shared observable | A long-lived process broadcasting messages |
| `Subscribe` | Register the caller PID and return a reference/handle |
| `Dispose` | Close the handle; the owner removes and demonitors the subscriber |
| `Subject` | A process mailbox plus explicit broadcast logic |
| `SelectMany(FromAsync(...))` | Start supervised tasks and handle result messages |
| `Publish().RefCount()` | Track consumer count; start first worker and stop the last |
| Replay under a lock | Snapshot plus subscription in one serialized server call |
| `CancellationToken` | Explicit close, timer cancellation, links, monitors, or process exit |
| Lock around state | One process owns state and serializes mailbox handling |
| `OnError` | The source process exits and its supervisor/monitors observe why |

The important phrase is "closest idea." Elixir still has lazy streams, tasks,
enumerables, and plain function composition. Not every Rx pipeline wants a
process. Conversely, a renewable network lease has an identity and lifetime,
so treating it as a process is often clearer than forcing it through a generic
stream abstraction.

## Where the .NET/Rx version shines

The .NET version retains substantial advantages:

- C#'s static type system makes the public object model highly discoverable.
- LINQ-style Rx composition is concise and expressive for transformations,
  filtering, switching, retry, and async fan-out.
- `Task`, `IAsyncEnumerable<T>`, and `IObservable<T>` let each API use the shape
  that best matches its cardinality.
- NuGet, IDE tooling, debuggers, analyzers, trimming, and the wider .NET
  ecosystem are excellent.
- Existing SSDP and listener libraries provide mature upstream building
  blocks.

For application code that already lives in .NET, UPnP.Rx is the obvious
integration. OTP is not a reason to move an otherwise happy system to another
runtime.

## Where OTP becomes exciting

OTP starts to feel special when the problem is made of many independent,
long-lived things:

- one process per network interface,
- one control point per application or tenant,
- one worker per remote event subscription,
- one process per renewable lease,
- one lazy callback server, and
- supervisors describing how those pieces depend on one another.

That topology is both implementation and operations documentation. If one
lease worker fails, its state and failure are isolated. If a consumer dies,
monitors clean up its registration. If a subscription worker must be replaced,
the manager knows which URL and local consumers it represented.

The runtime is built for systems that stay up while parts fail. That heritage
comes from telecoms, but UPnP turns out to be a charmingly small example of the
same shape: unreliable peers, leases, heartbeats, callbacks, retries, identity,
and partial failure.

## The honest costs

Elixir is not free magic.

- C# catches more API mistakes at compile time. Elixir type specifications are useful, but they are not the same contract as C# generics and nullable analysis.
- Mailboxes can grow. Message protocols and bounded state need the same discipline that Rx pipelines need around unbounded buffering.
- A GenServer that performs slow HTTP work in its callback becomes a bottleneck. The implementation must deliberately offload I/O and reconcile task results.
- Message ordering is guaranteed per sender, not globally. Correlation
  references and explicit ownership still matter.
- The Elixir ecosystem has fewer ready-made UPnP components, so the port owns
  its SSDP layer directly with `:gen_udp`.
- Process-per-thing can become process-for-everything if used without taste.
  Pure functions remain the better tool whenever no lifecycle exists.

OTP makes good boundaries pleasant; it does not choose those boundaries for
us.

## The most surprising result

After translating the implementation, the biggest discovery is how little the important engineering policy changed.

Both versions say:

- strict in what we send, lenient in what we accept;
- parsing is pure and total;
- one bad device does not kill the source;
- time is injectable and deterministic;
- slow work does not block the event coordinator;
- state replay and live delivery must have no race window;
- remote subscriptions are shared;
- finite leases are the safety net;
- graceful shutdown says goodbye;
- abrupt shutdown releases locally and lets the remote timeout win; and
- every accumulation needs a bound or expiry story.

Rx and OTP disagree less about correctness than they do about where the running system lives.

In UPnP.Rx, the system is most naturally seen as a graph: sources, operators, subscriptions, async edges, and disposables.

In OTP, the system is most naturally seen as a society: named roles, private state, messages, monitors, and supervisors.

For an Rx developer, that is the exciting part of Elixir. You do not have to give up streams or functional composition. You gain another dimension for the parts of the problem that have identity and lifecycle.

And UPnP - with its discovery chatter, expiring presence, renewable leases, inbound callbacks, and occasionally eccentric devices - is almost the perfect little workload for seeing why that matters.
