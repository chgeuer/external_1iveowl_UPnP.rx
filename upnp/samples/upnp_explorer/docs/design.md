# UPnP Explorer design

## Design read

UPnP Explorer is a LAN-native observability tool for curious home users and
developers. It should feel like a calm network instrument, not an admin template
or a synthetic topology map.

- Design variance: 4. A stable inspector layout with restrained asymmetry.
- Motion intensity: 3. Motion communicates arrival, removal, loading, and focus.
- Visual density: 7. Technical information is compact, but never undifferentiated.
- Foundation: Phoenix LiveView, Phoenix core components, Tailwind CSS, and a
  small application-specific token layer. No component design system is added.

## Product questions

The interface should answer these questions in order:

1. What is present on the home network now?
2. What can the selected device do?
3. What changed recently?
4. What protocol evidence supports that interpretation?

The default experience observes and explains. The service inspector also offers
an advanced executor for every well-formed SCPD action: forms and results are
generated from the contract, risk is stated before invocation, and anything not
confidently classified as a zero-input query requires a second confirmation.

## Source material

The application combines the strongest behavior already demonstrated in the
repository:

- The .NET dashboard contributes a live roster, hierarchical device inspection,
  on-demand SCPD loading, service event watching, per-device SSDP activity, and
  gateway inventory.
- The Elixir browser, eventing, port-mapper, and Bandit dashboard samples prove
  the equivalent OTP-native runtime capabilities.
- LiveView replaces the Bandit dashboard's periodic full-page refresh with
  bounded, event-driven updates.

## Information architecture

The application has three top-level destinations.

### Devices

This is the default route and the main working surface.

Desktop uses a three-pane inspector:

1. A roster pane lists discovered devices.
2. A detail pane explains the selected device.
3. An activity rail shows recent meaningful changes.

The roster contains:

- Friendly name, with model or network host as a reliable fallback.
- Manufacturer and model.
- A compact category and capability summary.
- Presence state: discovered, describing, online, or degraded.
- A semantic status marker only when it conveys real state.

Search matches friendly name, manufacturer, model, device type, host, and
service capability. Selecting a row updates the URL so a device can be
bookmarked or shared on the LAN.

The detail pane is progressively disclosed:

- Overview: identity, advertised location, device type, embedded-device summary.
- Services: human-readable capability names first, complete URNs second.
- Service detail: actions, argument directions, state variables, and eventing
  availability loaded only when requested.
- Action executor: SCPD input metadata generates selects, numeric constraints,
  defaults, and text fields; declared outputs retain wire order and device
  extensions remain visible.
- Safety policy: known standard actions get curated semantics. Unknown actions
  fail closed as state changes unless they have no inputs and a conventional
  read-action name. Destructive and connectivity-risk actions are unmistakable.
- Live events: an explicit watch starts a shared GENA subscription and displays
  replay, initial state, property changes, and lifecycle failures.
- Protocol details: raw identifiers and endpoint URLs grouped separately from
  the human-facing overview.

### Activity

Activity is a chronological explanation of the network.

The default Changes mode contains semantic events:

- Device appeared, updated, left, or expired.
- Description succeeded or failed.
- A manual search was sent.
- A service watch started, recovered, or failed.

Wire traffic is a separate mode containing SSDP alive, byebye, and search
responses. Consecutive equivalent packets are coalesced so normal announcement
traffic does not drown meaningful changes.

The feed is memory-bounded. It supports pause for inspection and resumes without
pretending that paused browser rendering stopped the network runtime.

### Gateway

Gateway is a separate read-only surface because it has a different mental model
and a higher security consequence than ordinary device browsing.

It shows:

- Gateway identity and WAN service.
- Connection status, uptime, local route, and external address.
- Current port mappings with protocol, external endpoint, internal target,
  description, and lease.

Creating or deleting mappings is intentionally deferred. A later control mode
must be session-scoped, clearly identify the target, distinguish mappings owned
by the application, and confirm mutations.

The generic service executor can still expose the gateway's advertised mapping
actions for protocol exploration. It does not turn them into managed leases or
claim ownership; each invocation is explicit, confirmed, and shown in Activity.

## Important interaction states

### Initial scan

The shell renders immediately with roster-shaped skeleton rows. It does not use
a blocking full-page spinner.

After five seconds with no devices, a contextual diagnostic panel appears. It
shows the interfaces being observed and suggests checking host networking,
Docker or WSL, VPN routing, AP isolation, and multicast handling. Discovery
continues while the panel is visible.

### Partial discovery

An SSDP response creates a roster row before the device description has loaded.
If description fetching fails, the row remains visible with the information
that SSDP supplied and an explicit degraded state. Observability must not hide
the failure it is meant to explain.

### Live update

New and updated rows receive a short surface highlight. Departed rows leave the
roster without decorative animation, while their departure remains in Activity.

### LiveView reconnect

The last rendered roster remains visible. A narrow connection notice states
that updates are paused and disappears after reconnection. Existing data is not
misrepresented as freshly confirmed.

### Errors

Failures stay near the operation that failed:

- Description failures stay on the affected device.
- SCPD failures stay inside the selected service.
- Action failures stay beside the action that was invoked.
- Confirmed state-changing outcomes also enter Activity so navigation cannot
  hide whether a real device operation completed.
- GENA lifecycle failures stay inside the live event section.
- Gateway discovery failures stay on the Gateway screen.

Flash messages are reserved for transient page-level outcomes.

## Visual system

### Theme

The page follows the operating-system light or dark preference and offers a
manual system, light, or dark choice. One theme applies to the complete page.

### Color

- Neutral surfaces carry hierarchy.
- Cyan is the single accent across navigation, focus, selection, and live state.
- Amber communicates degraded but usable data.
- Red is limited to failed operations.
- Green is limited to confirmed healthy protocol state.

There are no outer glows, multicolor gradients, or decorative status dots.

### Typography

- Human-readable text uses the native sans-serif stack.
- URNs, UDNs, addresses, ports, sequence numbers, and protocol values use the
  native monospace stack.
- Device names carry the strongest hierarchy. Protocol identifiers never
  compete with them.

### Shape and depth

- Panels use an 8px radius.
- Inputs use a 6px radius.
- Compact status labels may use a full pill.
- Most separation comes from spacing and hairlines. Shadows are reserved for
  the sticky shell and selected inspector surface.

### Motion

Only transform and opacity are animated. Motion is used for:

- Roster insertion and selection feedback.
- Disclosure transitions.
- Loading-state replacement.
- Button press feedback.

All motion is disabled or made instantaneous when reduced motion is requested.

## Responsive behavior

At widths below 900px:

- The roster becomes the default full-width screen.
- A selected device becomes a separate routed detail screen with a Back action.
- The activity rail is omitted from device detail and remains available through
  the Activity destination.
- Technical tables become stacked label-value groups rather than horizontal
  overflow where practical.

The navigation remains one line. Labels shorten before controls wrap.

## Accessibility

- Every interactive element is reachable by keyboard.
- Selection and presence are expressed in text as well as color.
- Focus indicators use the shared cyan accent and meet contrast requirements.
- Live updates use polite announcements only for meaningful state changes.
- Raw event streams do not continuously interrupt screen readers.
- Touch targets are at least 40px where space permits.
- Reduced-motion and operating-system color preferences are honored.

## Runtime design

- One named `UPnP.ControlPoint` runs under the application supervisor.
- `UpnpExplorer.Explorer` atomically subscribes to roster and announcement
  streams, describes devices through supervised tasks, and projects protocol
  structs into stable UI values.
- Phoenix PubSub carries device, status, and bounded activity changes to
  LiveViews.
- LiveViews use streams for roster, activity, service metadata, events, and
  port mappings.
- Action forms are generated from SCPD argument/state-variable metadata. The
  Explorer owns invocation tasks, records confirmed mutation outcomes, and
  replies to the initiating LiveView when it is still present.
- Service event subscriptions belong to the connected LiveView and are closed
  when the watch stops. The library's shared GENA manager prevents duplicate
  wire subscriptions.
- Test configuration starts the projection without multicast, so process and
  LiveView tests remain deterministic.

## First release acceptance

- The application boots without requiring a database.
- The root page renders immediately and sends a manual M-SEARCH on request.
- Discovered devices appear before and after description, with failures visible.
- Search filters the roster without restarting discovery.
- Device routes are deep-linkable.
- Service metadata loads on demand.
- Every well-formed advertised action has a generated executor.
- Non-query actions require an expiring, server-side confirmation.
- Inputs use SCPD defaults, choices, types, and valid numeric constraints.
- Results preserve declared output order and surface vendor extensions.
- Evented services can be watched and stopped.
- Changes and raw SSDP traffic are separate bounded feeds.
- Gateway status and mappings are inspectable without mutation.
- Empty, loading, degraded, disconnected, and error states are deliberate.
- The project passes `mix precommit`.
- A distributed development node can be started, queried over HTTP, and
  introspected through RPC.
