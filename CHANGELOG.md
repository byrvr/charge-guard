# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
