# Contributing to ChargeGuard

Thanks for your interest! This project is small and focused; contributions
that keep it that way are the most welcome.

## Ground rules

- **SMC safety first.** The helper writes exactly one SMC key (`CHTE`).
  PRs that add SMC writes need strong evidence of the key's semantics
  (Asahi Linux driver sources, established open-source tools) and must
  validate layout before writing and read back after. Blind writes to
  undocumented keys will not be merged.
- **Crash-safety invariants are load-bearing.** Any change to the engine
  must preserve: charging force-enabled on start/clean exit, LPM baseline
  persisted before modification, state re-asserted while guarding, and
  sleep-immune timing (`CLOCK_UPTIME_RAW`).
- Keep the helper minimal — it runs as root. UI logic belongs in the app.

## Workflow

1. Fork, branch from `main` (`feat/...`, `fix/...`, `docs/...`).
2. `brew install xcodegen && xcodegen` — the `.xcodeproj` is generated
   from `project.yml`; edit the manifest, not the project file.
3. Make your change; build the `ChargeGuard` scheme.
4. Use [Conventional Commits](https://www.conventionalcommits.org)
   (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`) — the history is part of
   the documentation.
5. Open a PR with: what, why, and how you tested (this project's test rig
   is a genuinely bad charger; describe yours).

## Testing without a flaky charger

You can simulate flapping by toggling charging by hand (watch Activity in
the menu) — or lower `flapTrigger`/`flapWindow` in Settings and unplug/replug
your charger a few times. Please always verify after testing that charging
is re-enabled (`pmset -g batt` shows `charging` when plugged in).

## Reporting bugs

Use the issue templates. Always include: Mac model, macOS version, charger
rating, and the Activity log around the misbehavior.
