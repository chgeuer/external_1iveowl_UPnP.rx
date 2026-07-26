# `:upnp` Idiomatic Elixir Remediation Campaign

This is a resumable, one-issue-per-run campaign. All progress lives in the `br`
tracker under `upnp/.beads`. Each run takes exactly one approved AFK issue to
Done, commits it, closes it, writes a handoff, and stops.

This repository contains both the released .NET UPnP.Rx library and the
OTP-native Elixir `:upnp` application. Campaign code changes are restricted to
`upnp/`. Preserve protocol correctness and lifecycle semantics; never weaken a
test, timeout, parser, input bound, or failure mode merely to make a gate pass.

## Mission

Take one ready, non-epic issue labeled both `idiomatic-elixir-2026-07` and
`afk` to Done. Confirm the issue against current code before changing anything:
findings are hypotheses, and an obsolete or incorrect finding must be closed as
`wontfix` with a concrete explanation rather than forced into a code change.

If only `hitl` work is ready, do not claim it. Report the decision needed and
stop so the driver can surface it to a human.

## Read first

1. `AGENTS.md` and `CLAUDE.md` at the repository root.
2. `upnp/README.md` for the Elixir public Interface and lifecycle contracts.
3. `upnp/docs/rx_versus_otp.md` for the intended Rx-to-OTP design translation.
4. The complete selected issue: run `cd upnp && br show <id>`.
5. Its dependencies and comments: `cd upnp && br dep list <id> && br comments <id>`.

The `br` issue body is the authoritative finding description and acceptance
criteria. Do not re-open decisions already encoded there.

## Environment and baseline

- Repository root: the directory containing this prompt.
- Elixir project and tracker: `upnp/`.
- Toolchain: Elixir 1.20, Mix, `br`, Git, .NET 10, and Copilot CLI are installed.
- Automated tests must not require multicast or a real LAN. Use the existing
  HTTP, UDP, GENA, route, and clock Adapter seams.
- `mix format --check-formatted`, forced warning-free compilation, and ExDoc
  currently pass.
- The suite contains 77 tests. Before `bd-l0f`, seed `971129` can fail under
  concurrent scheduling but passes serially. `bd-l0f` is therefore the first
  implementation issue.
- Coverage currently reports 78.43% against a 90% threshold. Until `bd-8o6`,
  78.43% is the non-regression floor; `bd-8o6` must make the 90% gate green.

## Where the work lives

- Campaign label: `idiomatic-elixir-2026-07`.
- Epic: `bd-3lm` — Harden `:upnp` OTP architecture and public interfaces.
- Tracker: `upnp/.beads`.
- Focus labels: `integrity`, `idiomatic`, and `maintainability`.
- Severity labels: `sev-high`, `sev-medium`, and `sev-low`.
- Execution labels: `afk` is approved for unattended work; `hitl` requires a
  recorded human decision before implementation.

No separate audit markdown is required: each issue contains its location,
problem, intended outcome, dependencies, and acceptance criteria.

## Order of work

1. Work only on ready issues carrying both the campaign label and `afk`.
2. Take `bd-l0f` first so later full-suite verification is trustworthy.
3. Follow `br` dependency edges, then priority: P1 before P2 before P3.
4. At equal priority, prefer `integrity`, then `idiomatic`, then
   `maintainability`.
5. `bd-8o6` is the final gate and remains blocked until all preceding slices
   are complete.
6. Never claim `hitl` issues `bd-2vi` or `bd-dt3` without a human decision
   recorded in their comments and their label changed to `afk`.

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
br ready -l idiomatic-elixir-2026-07 -l afk --limit 0
br update <id> --claim
br show <id>
br comments <id>
```

If no AFK issue is ready, do not claim a HITL issue. Stop and describe the
decision or dependency that blocks further unattended work.

## Do the work end to end

1. **Confirm** the stated gap in current code and reproduce it when applicable.
2. **Prove the gap** with a focused regression, property, or failure-injection
   test that fails before the fix and passes after it.
3. **Implement** the smallest coherent change satisfying every acceptance
   criterion. Preserve existing naming and design conventions unless the issue
   explicitly changes them.
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
fix(upnp): make eventing startup deterministic (bd-l0f)
chore(beads): close bd-l0f
```

Do not add `Co-authored-by` trailers.

## Definition of Done

Every applicable item must pass before the issue is closed.

1. The new regression test demonstrably fails before the fix and passes after.
2. From `upnp/`:

   ```bash
   mix format --check-formatted
   mix compile --force --warnings-as-errors
   mix test <targeted test files or line selectors>
   mix test
   ```

3. Run `mix test --cover`.
   - Before `bd-8o6`, exit code 3 is acceptable only when all tests pass and the
     sole failure is the configured 90% threshold; total coverage must remain
     at or above 78.43%.
   - For `bd-8o6` and every later state, the command must exit 0 at 90% or more.
   - Any test failure is a blocker regardless of the percentage.
4. If public docs, module docs, types, examples, or package metadata changed:

   ```bash
   mix docs --warnings-as-errors
   ```

5. From the repository root, preserve the parent repository gate:

   ```bash
   dotnet build UPnP.Rx.slnx -c Release
   dotnet test UPnP.Rx.slnx -c Release
   ```

6. From `upnp/`, tracker integrity remains clean:

   ```bash
   br lint
   br dep cycles
   ```

7. `git status --short` contains no unrelated, staged, or modified files before
   closing. After the code commit and tracker commit, the tracked tree is clean.

## Guardrails

- One issue per run. Claim before editing; stop immediately after closing it.
- Change code, tests, docs, and package files only under `upnp/`. The campaign
  mechanism at repository root is operator-owned and must not be edited.
- Preserve OTP ownership and restart semantics. Graceful close must perform
  protocol goodbyes; abrupt owner/process loss must not invent them.
- Keep network and protocol failures as tagged data where documented. Do not
  replace them with broad rescues, silent fallbacks, or process crashes.
- Receive-side parsers remain pure, total for their declared input types, and
  lenient toward malformed optional fields. Send-side composition remains
  strict and injection-safe.
- Preserve hard request, response, datagram, callback-body, retry, and queue
  bounds.
- `UPnP.Clock` is the single protocol clock. Tests use one manual clock and no
  wall-clock sleeps.
- Never create atoms from network input.
- Tests use fake Adapters and loopback-only infrastructure; never depend on
  multicast, real gateways, devices, or external services.
- Do not add runtime dependencies or alter the .NET/upstream libraries.
- Never dismiss a failing test as flaky or pre-existing. Reproduce and either
  resolve it within the claimed issue or stop with a concrete blocker.
- Never weaken acceptance criteria, coverage thresholds, compiler warnings, or
  documentation checks.

## Stop and hand off

Finish the response captured in the run log with:

```markdown
## Session summary

- Issue: <id and title>
- Result: <closed/wontfix/blocked>
- Commits: <hashes>
- Regression: <test>
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
br list -l idiomatic-elixir-2026-07 --status open --limit 0
br ready -l idiomatic-elixir-2026-07 -l afk --limit 0
```

The campaign is complete when all ten children of `bd-3lm` are closed and the
epic is eligible to close.
