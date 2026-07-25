# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-07-25

### Fixed

- **The watt ceiling looked ignored after moving the slider.** The energy
  integrator and the reported average are both relative to a ceiling — at 45W
  they settle on 45W and ~60% duty — and they were carried across a slider
  move. So a fresh 30W ceiling spent the length of the average's time constant
  reporting the *previous* setting's steady state: 47W and 66% under a 30W cap,
  which reads exactly like the cap doing nothing. Changing the ceiling (or
  switching the limit on) now restarts the measurement.
- **Half-formed averages are no longer published.** The figures are
  exponential averages seeded from the first reading, so for the first minute
  they are mostly that first reading. The panel says "Measuring" until there is
  about a cycle and a half of history behind them.
- The menu panel showed the instantaneous draw while the settings panel showed
  the average, so the two disagreed by ~30W mid-burst. Both now show the
  average whenever the ceiling is on.

### Changed

- **One version number.** The app and the helper are one product; they now
  share a single constant (`Shared/Version.swift`, stamped into the app bundle
  by `scripts/sync-version.sh`) and the UI shows it once. Two numbers appear
  only when they genuinely differ — a new app against a helper that was never
  reinstalled — and then it says so and points at Update Helper.

## [0.2.0] - 2026-07-19

### Added

- **Experimental PD downshift.** Instead of only pausing charging, the guard
  can renegotiate the USB-C Power Delivery contract down to a lower advertised
  profile (45W / 36W / 27W) so the battery keeps charging on a weak charger.
  Driven through the `AppleHPM` Type-C controller interface, gated behind a
  read-only probe that confirms the controller's register layout, restricted
  to volatile registers with a strict 4CC whitelist (no flash/OTP), and
  self-verifying with auto-revert. Off by default; CHTE charge-inhibit remains
  the fallback.
- App icon.
- Live adapter draw in the menu panel (from the SMC `PDTR` sensor).
- "Start ChargeGuard at login" toggle.

### Fixed

- Settings window now opens to the front from the menu bar panel.
- Panel text wraps instead of truncating; unregistered daemon reads as a
  first-run state rather than an error; monochrome palette.

[0.2.0]: https://github.com/byrvr/chargeguard/releases/tag/v0.2.0

## [0.1.0] - 2026-07-19

### Added

- Guard engine: flap detection over a sliding window, charge inhibition
  via the SMC `CHTE` key, probing with exponential backoff, immediate
  re-engage after a recent guard, early probe on suspected charger swap.
- Crash safety: charging force-enabled on start/clean exit; Low Power Mode
  baseline persisted to disk before modification and recovered after
  unclean exits; per-cycle state reconciliation while guarding.
- Sleep-immune timing via `CLOCK_UPTIME_RAW` plus probe voiding on wake.
- Privileged helper (LaunchDaemon via `SMAppService`) with an XPC API.
- SwiftUI menu bar app: live status, activity log, tunable settings,
  manual "Charge Now" override.
- Optional AC Low Power Mode while guarding.

[0.1.0]: https://github.com/byrvr/chargeguard/releases/tag/v0.1.0
