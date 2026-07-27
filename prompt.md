# `:upnp` Critical Audit Remediation Campaign — `audit-2026-07`

This is a resumable, one-issue-per-run campaign. All progress lives in the `br`
tracker under `upnp/.beads`. Each run takes exactly one approved AFK issue to
Done, commits it, closes it, writes a handoff, and stops.

This repository contains both the released .NET UPnP.Rx library and the
OTP-native Elixir `:upnp` application. Campaign code changes are restricted to
`upnp/`. Preserve protocol correctness and lifecycle semantics; never weaken a
test, timeout, parser, input bound, or failure mode merely to make a gate pass.

**What this campaign is about.** A four-lens adversarial audit found that a
`UPnP.ControlPoint` can be **permanently and silently destroyed by a handful of
unauthenticated UDP datagrams from any host on the LAN**, and that its presence
roster grows without bound from spoofed announcements. Every finding in this
campaign was *reproduced against running code*, not merely inferred. The theme
is one sentence: **untrusted network input reaches the coordinator unchecked,
and the supervision tree turns any crash into a permanent outage.**

## Mission

Take one ready, non-epic issue labeled both `audit-2026-07` and `afk` to Done.
Confirm the issue against current code before changing anything: findings are
hypotheses, and an obsolete or incorrect finding must be closed as `wontfix`
with a concrete explanation rather than forced into a code change.

If only `hitl` work is ready, do not claim it. Report the decision needed and
stop so the driver can surface it to a human.

## Read first

1. `AGENTS.md` and `CLAUDE.md` at the repository root.
2. `upnp/README.md` for the Elixir public interface and lifecycle contracts.
3. `upnp/docs/rx_versus_otp.md` for the intended Rx-to-OTP design translation.
4. The complete selected issue: run `cd upnp && br show <id>`.
5. Its dependencies and comments: `cd upnp && br dep list <id> && br comments <id>`.

The `br` issue body is the authoritative finding description and acceptance
criteria. There is no separate audit markdown in this repository: each issue
carries its own **What to fix**, **Steps to Reproduce**, and **Acceptance
criteria** sections, including the exact measured numbers from the audit. Do not
re-open decisions already encoded there.

## Environment and baseline

- Repository root: the directory containing this prompt.
- Elixir project and tracker: `upnp/`. Run every `mix` and `br` command from
  there unless stated otherwise.
- Toolchain: Elixir 1.20 on OTP 29, Mix, `br`, Git, .NET 10, and Copilot CLI are
  installed.
- Automated tests must not require multicast or a real LAN. **Multicast does not
  work in this container.** Use the existing HTTP, UDP, GENA, route, and clock
  adapter seams. `UPnP.ControlPoint.inject/2` and the `UPnP.SSDP.Transport`
  behaviour are the seams the audit itself used to reproduce every finding.
- Clean baseline, all currently passing:
  - `mix format --check-formatted` clean.
  - `mix compile --force --warnings-as-errors` clean.
  - `mix test` reports **151 passed (2 properties, 149 tests)**.
  - `mix test --cover` reports **90.57% total** and exits **0** against the 90%
    threshold. 90.57% is the non-regression floor; the gate must keep exiting 0.
  - `mix deps.unlock --check-unused` and `mix hex.audit` clean.
- `mix credo` and `mix dialyzer` are **not** configured in this project. Do not
  add them as part of a campaign issue; there is no lint baseline to match.
- **Known flake, do not paper over it.** `test/control_point_runtime_test.exs:180`
  ("a graceful close stops every owned process and is idempotent") has an
  `assert_receive` with a 100 ms deadline that has been observed to time out
  intermittently and then pass on re-run with the same seed. If that *exact*
  test fails, re-run it once with the same seed to confirm. If it reproduces
  deterministically, that is a real regression and a blocker. This is the only
  test with a known flake; treat **every** other failure as real.
- **Coverage exclusions matter here.** `mix.exs` excludes `UPnP.Clock.System`,
  `UPnP.Network.System` and `UPnP.SSDP.Transport.System` from coverage. That
  exclusion is precisely why `bd-2cp` escaped the suite: the real clock, the
  module that actually raises, is never exercised. Prefer tests that close that
  blind spot over tests that only exercise the fake.
- `upnp/samples/upnp_explorer/` is a **separate Mix project** (it has its own
  `mix.exs` and its own `AGENTS.md`) containing in-progress Phoenix work owned by
  the author. It is tracked in git as of commit `8e021ff`, and it currently fails
  `mix compile --warnings-as-errors` with undefined-attribute and unmatched-route
  warnings. That is the author's work in progress, **not** a campaign defect. It
  is outside the library's compile and test gates, so it cannot affect them.
  Never modify it, never compile it as part of a gate, and never include it in a
  campaign commit.

## Where the work lives

- Campaign label: `audit-2026-07`.
- Epic: `bd-3ez` — Remediate critical control-point defects from the 2026-07 audit.
- Tracker: `upnp/.beads`.
- Focus labels: `security`, `resilience`, and `performance`.
- Severity labels: every child is `sev-critical`.
- Execution labels: `afk` is approved for unattended work; `hitl` requires a
  recorded human decision before implementation.

The four children and how they relate:

| Issue | Focus | Summary |
| --- | --- | --- |
| `bd-2cp` | security | Clamp untrusted SSDP `max-age` before scheduling roster expiry timers |
| `bd-16w` | resilience | Make SSDP datagram parsing total so a malformed `LOCATION` cannot raise |
| `bd-1e5` | performance | Bound the presence roster and its per-entry expiry timers |
| `bd-3nj` | resilience, **hitl** | Survive crash storms instead of silently and permanently destroying the control point |

`bd-2cp` and `bd-16w` remove the two known crash triggers. `bd-1e5` removes the
memory-exhaustion route. `bd-3nj` removes the amplifier that turns any crash into
a permanent, silent outage, and it is human-gated because it changes restart and
failure domains, exactly as `bd-2vi` was in the previous campaign.

## Order of work

1. Work only on ready issues carrying both the campaign label and `afk`.
2. Take `bd-2cp` first. It is the smallest correct fix, and it unblocks both
   `bd-1e5` and `bd-3nj`.
3. Then `bd-16w`, which completes the "no datagram may ever raise" invariant.
4. Then `bd-1e5`, which depends on sane expiry timers already being in place.
5. `bd-3nj` is last and is `hitl`. Never claim it without a human decision
   recorded in its comments and its label changed to `afk`.
6. Otherwise follow `br` dependency edges, then priority, then focus order:
   `security`, then `resilience`, then `performance`.

## Orient first

If earlier runs left a handoff, skim the newest completed log:

```bash
grep -l '## Next-agent prompt' .campaign/logs/*.log 2>/dev/null |
  xargs -r ls -t |
  head -1
```

Treat it only as a hint. `br` is authoritative.

## Pick and claim exactly one issue

```bash
cd upnp
br ready -l audit-2026-07 -l afk --limit 0
br update <id> --claim
br show <id>
br comments <id>
```

If no AFK issue is ready, do not claim a HITL issue. Stop and describe the
decision or dependency that blocks further unattended work.

## Do the work end to end

1. **Confirm** the stated gap in current code, and **reproduce it** using the
   issue's *Steps to Reproduce*. Every issue in this campaign was reproduced
   during the audit, so a failure to reproduce is significant information: say so
   explicitly rather than proceeding on faith.
2. **Prove the gap** with a focused regression, property, or failure-injection
   test that fails before the fix and passes after it. For this campaign that
   normally means a hostile-input test: an absurd header value, invalid UTF-8, or
   a flood of unique spoofed identities.
3. **Implement** the smallest coherent change satisfying every acceptance
   criterion. Preserve existing naming and design conventions unless the issue
   explicitly changes them. Where the tree already contains a correct defensive
   pattern, reuse it rather than inventing a second style.
4. **Verify** the complete Definition of Done below.
5. **Commit code and tests** by staging explicit paths only. Never use
   `git add -A` or `git add .`.
6. **Close the issue** from `upnp/`:

   ```bash
   br close <id> -r "Resolved in <hash>. <behavior changed>. Regression: <test>."
   ```

7. Stage only `upnp/.beads/issues.jsonl` and commit that tracker update.
8. Stop. Do not inspect or begin another issue.

If the issue is already fixed or false, close it with
`wontfix: <specific current-code evidence>`, commit only the tracker change, and
stop.

Commit messages must reference the issue, for example:

```text
fix(upnp): clamp untrusted SSDP max-age before scheduling timers (bd-2cp)
chore(beads): close bd-2cp
```

Do not add `Co-authored-by` trailers.

## Definition of Done

Every applicable item must pass before the issue is closed.

1. The new regression test demonstrably fails before the fix and passes after.
   State both observed outcomes in your handoff.
2. From `upnp/`:

   ```bash
   mix format --check-formatted
   mix compile --force --warnings-as-errors
   mix test <targeted test files or line selectors>
   mix test
   ```

3. From `upnp/`, `mix test --cover` exits 0 at 90% or more. Total coverage must
   not fall below the 90.57% baseline. Any test failure is a blocker regardless
   of the percentage.
4. If public docs, module docs, types, examples, or package metadata changed:

   ```bash
   mix docs --warnings-as-errors
   ```

5. The .NET gate. `UPnP.Rx.slnx` contains only the C# projects under `src/`,
   `tests/` and `samples/Sample.*`, which are disjoint from `upnp/`. Run it only
   if your change touched anything outside `upnp/`:

   ```bash
   dotnet build UPnP.Rx.slnx -c Release
   dotnet test UPnP.Rx.slnx -c Release
   ```

   This is a scoping decision, not a relaxation: an Elixir-only change cannot
   affect that solution.
6. From `upnp/`, tracker integrity remains clean:

   ```bash
   br lint
   br dep cycles
   ```

7. `git status --short` contains no unrelated, staged, or modified files before
   closing. `samples/upnp_explorer/` must be left byte-for-byte as found. After
   the code commit and tracker commit, the tracked tree is clean.

## Guardrails

- One issue per run. Claim before editing; stop immediately after closing it.
- Change code, tests, docs, and package files only under `upnp/`. The campaign
  mechanism at repository root is operator-owned and must not be edited. Never
  touch `samples/upnp_explorer/`.
- **No input from the network may raise.** Receive-side parsers are pure, total
  for their declared input types, and lenient toward malformed optional fields.
  An unparsable optional field stays unset; only a document that identifies
  nothing may fail. Send-side composition remains strict and injection-safe.
- **No input from the network may allocate without bound.** Preserve and extend
  hard request, response, datagram, callback-body, retry, queue, roster, timer,
  and cache bounds. Never reintroduce an unbounded collection or an unbounded
  timer delay.
- **Never trust a duration, count, or identity taken from the wire.** Clamp it
  against a documented ceiling before it reaches a scheduler, an allocation, or a
  map key.
- Preserve OTP ownership and restart semantics. Graceful close must perform
  protocol goodbyes; abrupt owner or process loss must not invent them.
- Keep network and protocol failures as tagged data where documented. Do not
  replace them with broad rescues, silent fallbacks, or process crashes. A broad
  `rescue` that swallows a real bug is not a fix for a crash finding.
- `UPnP.Clock` is the single protocol clock. Tests use one manual clock and no
  wall-clock sleeps.
- Never create atoms from network input.
- Do not weaken the existing, audited defenses: Saxy's `expand_entity: :keep`,
  the byte bounds on every network read path, the 256-bit callback tokens, or
  their constant-time comparison via `Plug.Crypto.secure_compare`.
- Tests use fake adapters and loopback-only infrastructure; never depend on
  multicast, real gateways, devices, or external services.
- Do not add runtime dependencies or alter the .NET or upstream libraries.
- Never dismiss a failing test as flaky or pre-existing. The single documented
  exception is `test/control_point_runtime_test.exs:180`, described above, and
  even that must be re-run to confirm rather than assumed. Anything else:
  reproduce and either resolve it within the claimed issue or stop with a
  concrete blocker.
- Never weaken acceptance criteria, coverage thresholds, compiler warnings, input
  bounds, or documentation checks.

## Stop and hand off

Finish the response captured in the run log with:

```markdown
## Session summary

- Issue: <id and title>
- Result: <closed/wontfix/blocked>
- Reproduction: <did the documented repro reproduce, yes or no, and what you saw>
- Commits: <hashes>
- Regression: <test, and the fails-before/passes-after evidence>
- Verification: <commands and outcomes>

## Next-agent prompt

<next ready AFK issue, relevant neighboring changes, or the exact human
decision/blocker that prevents progress>
```

Then stop. The driver, not this run, decides whether another issue starts.

## Progress check

```bash
cd upnp
br epic status
br list -l audit-2026-07 --status open --limit 0
br ready -l audit-2026-07 -l afk --limit 0
```

The campaign is complete when all four children of `bd-3ez` are closed and the
epic is eligible to close. Because `bd-3nj` is `hitl`, the unattended loop will
legitimately stop before it with "no AFK issue ready"; that is a successful
completion of the unattended portion, not a failure.
