
## [Unreleased]

### Features

- garbage collector: remove old revisions (keep 0, stable and running), their objects and stale logs
- configurable via PH_GC_INTERVAL / PH_GC_LOGS_MAX_AGE and the device.json gc block

### Bug Fixes

- keep the daemon alive through Pantahub outages (retry login, skip api cycles, still gc)
- default build/test optimize to ReleaseSafe (-Doptimize still overrides)
- fix local_store inline test for the 0.15 ArrayList API and run it in CI


## [v0.2.0] - 2026-08-11

### Features

- per-device configs and container-native swarms


## v0.1.0 - 2026-08-11

### Bug Fixes

- support local revisions
- use patch instead of put for device-meta push
- readme add new swarm documentation
- remove reference to gitlab

### Features

- drive swarm mode from a single swarm.json config
- auto-disable HTTPS for local and private addresses
- swarm generate add the models into the mocks.json
- add pvcontrol server with local revisions support
- add documentation about the --auto mode
- add auto to use automation inside mocker.json
- swarm use workspace and simulate should use ctrl + c
- add test to ci
- add pvcontrol server socket
- add swarm subcommand to run fleet of mocks devices
- create a framework to run CLI commands
- add --host and --port arguments to init command

### Maintenance

- project review — fix leaks/perf, add CI and tests


[v0.2.0]: https://github.com/pantavisor/pantavisor-mocker/compare/v0.1.0...v0.2.0
