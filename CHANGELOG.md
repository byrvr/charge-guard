# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
