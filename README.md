# Pantavisor Mocker

Pantavisor Mocker is a tool designed to mock the functionality of [Pantavisor](https://pantavisor.io/) and how it interacts with [Pantahub](https://api.pantahub.com). It allows you to simulate core device operations—such as registration, metadata synchronization, and OTA (Over-The-Air) update flows—without requiring actual hardware or a full Pantavisor runtime.

Everything is driven by single-file JSON configs: a [`device.json`](#one-file-device-config-devicejson) describes one device, a [`swarm.json`](#swarm-mode-fleet-simulation) describes a whole fleet — locally, in [Docker](#running-in-docker), or in [Kubernetes](#running-in-kubernetes).

## Quick Start

Get the binary (see [Build and Installation](#build-and-installation)) or use the Docker image `ghcr.io/pantavisor/pantavisor-mocker:latest`. You need a Pantahub **auto-join token** so devices can register themselves.

**Simulate one device** — describe it in one JSON and start it:

```bash
cat > device.json <<'EOF'
{
  "pantahub": { "host": "api.pantahub.com", "port": "443", "autojoin_token": "YOUR_AUTO_TOKEN" },
  "device-meta": { "pantavisor.dtmodel": "My Test Device" },
  "automation": { "enabled": true }
}
EOF

pantavisor-mocker start -s my-device -c device.json
```

The mocker registers a new device with the auto-token, syncs metadata, and processes OTA updates. All state — including the device identity — lives in `my-device/`, so running the same command again resumes the same device.

**Simulate a fleet (swarm)** — one `swarm.json` describes the whole fleet:

```bash
pantavisor-mocker swarm init -d my-fleet   # writes a swarm.json template
vim my-fleet/swarm.json                    # set pantahub.host + autojoin_token
pantavisor-mocker swarm run -d my-fleet    # generate the fleet + simulate it
```

**Simulate a fleet in containers** — one device per container, with per-device logs:

```bash
cp my-fleet/swarm.json examples/docker/ && cd examples/docker
docker compose up -d --scale device=10
docker compose logs -f
```

See [Running in Docker](#running-in-docker) and [Running in Kubernetes](#running-in-kubernetes) for details.

## What is Pantavisor?

[Pantavisor](https://pantavisor.io/) is a framework for building embedded Linux systems using lightweight Linux Containers (LXC). It turns the entire userland, including the OS, networking, and applications, into modular, portable, and manageable building blocks.

Pantavisor Mocker specifically simulates the **Pantavisor Runtime** behavior regarding:

- **State JSON**: A declarative description of the system state, defining the set of containers, BSPs, and configurations that should be running.
- **Trails & Revisions**: The history of state changes. Every update creates a new immutable **Revision**, forming a **Trail**.
- **Objects**: The content-addressable artifacts (container images, firmware, configs) that make up a revision.
- **Update Lifecycle**: The atomic transition from one revision to another, including download, verification, installation, testing, and potential rollback.

## Features

- **Single-file JSON configuration**: one `device.json` per device, one `swarm.json` per fleet — including the Pantahub endpoint, token, metadata and automation behavior.
- **Container-native swarms**: run one device per Docker container or Kubernetes pod (`swarm device`), or a whole fleet in one container (`swarm run --headless`).
- **Device Registration**: Automatically registers a new device using a factory auto-token.
- **Metadata Synchronization**:
  - Syncs **Device Metadata** (system info, storage, etc.) to the cloud.
  - Syncs **User Metadata** from the cloud to the local device.
  - Supports `mocker.json` for injecting custom metadata values.
- **Update Flow Simulation**:
  - Fetches update steps iteratively from Pantahub.
  - Downloads and validates update artifacts (objects) using signed URLs.
  - Simulates the full Pantavisor state machine:
    - `QUEUED` -> `DOWNLOADING` -> `INPROGRESS` -> `TESTING` -> `DONE`
  - **Interactive Testing**: Allows manual User Acceptance Testing (UAT) during the `TESTING` phase via CLI (Pass/Fail).
  - **Robust Recovery**: Handles interrupted updates and implements immediate rollback on failure.
- **Logging**: Captures and pushes logs to Pantahub.
- **pvcontrol Server**: Provides a Unix domain socket server that implements the Pantavisor Control API, allowing container-side tools like `pvcontrol` to interact with the mocker.
- **Fleet Invitation Protocol**: Simulates user consent flows (Accept/Skip) for managed fleet-wide updates.
- **Garbage Collector**: Periodically removes old revisions (always keeping revision 0, the stable/rollback revision and the running one), deletes their objects and stale logs; retention is configurable.
- **TLS Ownership Validation**: Supports device ownership verification using client-side TLS certificates.

## Configuration

### One-file device config: `device.json`

The recommended way to configure a single device is one JSON file, applied with `init -c` or `start -c`:

```json
{
  "pantahub": {
    "host": "api.pantahub.com",
    "port": "443",
    "autojoin_token": "YOUR_AUTO_TOKEN"
  },
  "device-meta": {
    "pantavisor.arch": "aarch64/64/EL",
    "pantavisor.dtmodel": "My Test Device",
    "custom.site": "lab-1"
  },
  "automation": { "enabled": true, "update": { "done": 100 } },
  "intervals": { "devmeta": 10, "usrmeta": 10 },
  "gc": { "interval": 3600, "logs_max_age": 604800 },
  "ownership": { "cert": "certs/cert.pem", "key": "certs/key.pem" }
}
```

| Key | Purpose |
|-----|---------|
| `pantahub.host` / `pantahub.port` | Pantahub API endpoint (port may be a string or a number) |
| `pantahub.autojoin_token` | Auto-join token used for device registration |
| `device-meta` | Custom device metadata pushed to the cloud |
| `automation` | Auto-respond behavior for invitations/updates (see [Automation Configuration](#automation-configuration)) |
| `intervals.devmeta` / `intervals.usrmeta` | Metadata sync intervals in seconds |
| `gc.interval` / `gc.logs_max_age` | Garbage collector: run interval and log retention, in seconds (see [Garbage Collector](#garbage-collector)) |
| `ownership.cert` / `ownership.key` | Optional TLS client cert/key (PEM) copied into `storage/ownership/`; paths are relative to the config file (see [TLS Ownership Configuration](#tls-ownership-configuration)) |

```bash
# apply once, then start
pantavisor-mocker init -s my-device -c device.json
pantavisor-mocker start -s my-device

# or apply on every start (initializes the storage on first run)
pantavisor-mocker start -s my-device -c device.json
```

Re-applying is always safe: the registration credentials the device obtains (`PH_CREDS_PRN`/`PH_CREDS_SECRET`) are never touched, so the device keeps its identity. On `init`, the `--token/--host/--port` flags override the file's values, and `--cert/--key` override its `ownership` block.

The rest of this section describes the files inside the storage directory that the device config writes for you — useful to understand or tweak a device by hand.

### Main Configuration: `storage/config/pantahub.config`

This file contains the core connectivity and credential settings. Key parameters include:

- `PH_CREDS_HOST`: Pantahub API host (default: `api.pantahub.com`).
- `PH_CREDS_PORT`: API port (default: `443`).
- `PH_CREDS_PRN`: The Device ID (PRN). Populated automatically after registration.
- `PH_CREDS_SECRET`: The Device Secret. Populated automatically after registration.
- `PH_FACTORY_AUTOTOK`: The auto-token used for initial device registration (required for new devices).
- `PH_METADATA_DEVMETA_INTERVAL`: Interval (in seconds) to push device metadata.
- `PH_METADATA_USRMETA_INTERVAL`: Interval (in seconds) to pull user metadata.
- `PH_GC_INTERVAL`: Interval (in seconds) between garbage collector runs; `0` disables the GC (default: `3600`).
- `PH_GC_LOGS_MAX_AGE`: Delete a revision's logs after this many seconds without writes; `0` keeps them until the revision is removed (default: `604800` = 7 days).

### Garbage Collector

Every `PH_GC_INTERVAL` seconds the mocker reclaims storage occupied by superseded revisions. The keep set is:

- **Revision 0** — the factory revision.
- **The stable revision** — the rollback point while an update is in flight.
- **The running revision** (`try_rev`).

Everything else under `trails/` and `logs/` is deleted (a device at revision 9 keeps only 0 and 9; during an update to 10, revision 9 is protected as the rollback point).

Objects are content-addressed and shared across revisions, so each revision records the objects it needs in a manifest (`trails/<rev>/.pvr/objects`, written by the update flow and by `pvcontrol` object uploads). The GC protects the union of the kept revisions' manifests and deletes any other file in `objects/` — objects shared with a kept revision survive. Storages that predate manifests keep all objects until their next successful update writes one.

Log directories of removed revisions are deleted along with the revision; log dirs of kept revisions are additionally deleted after `PH_GC_LOGS_MAX_AGE` seconds without writes (the running revision's log is always kept).

### Metadata Overrides: `storage/config/mocker.json`

You can inject custom device metadata values by creating this JSON file.

**Example `storage/config/mocker.json`**:
```json
{
  "device-meta": {
    "custom.hardware.revision": "v2.0",
    "location.site": "Lab-1"
  }
}
```

### TLS Ownership Configuration

To simulate a device that proves its ownership via TLS client certificates, the mocker needs the client certificate and private key (PEM) at `storage/ownership/cert.pem` and `storage/ownership/key.pem`. The mocker does not generate them; use a pair issued by the PKI Pantahub trusts for ownership validation. Any of these puts them in place:

```bash
# init flags (both required together); copied into <storage>/ownership/
pantavisor-mocker init -s my-device -t YOUR_AUTO_TOKEN --cert ./cert.pem --key ./key.pem

# or an "ownership" block in device.json / swarm.json (paths relative to that file)
#   "ownership": { "cert": "certs/cert.pem", "key": "certs/key.pem" }
pantavisor-mocker init -s my-device -c device.json

# or by hand
mkdir -p my-device/ownership && cp cert.pem key.pem my-device/ownership/
```

In swarm mode the pair from `swarm.json` is copied into every device provisioned by `swarm generate-*`, `swarm run` and `swarm device`, so all devices of the fleet share the same cert. The key is installed with mode `0600`.

When the mocker starts, if these files exist and the device has not yet been verified (indicated by `ovmode_status` in device metadata), the mocker will:
1. Authenticate with Pantahub to obtain a temporary token.
2. Call the ownership validation endpoint using the provided TLS certificate and key.
3. Upon success, update the local device metadata (`ovmode_status: completed`) and proceed with normal operation.

## Running in Docker

The pre-built image `ghcr.io/pantavisor/pantavisor-mocker:latest` (also tagged per release, e.g. `:v0.1.0`) has the CLI as its entrypoint. Since containers have no TTY for the interactive prompts, enable `automation` in your config so devices answer invitations and updates on their own.

### Single device

Mount a [`device.json`](#one-file-device-config-devicejson) and a storage volume; the device initializes itself on first start and keeps its identity in the volume:

```bash
docker run -d --name my-device \
	-v ${PWD}/device.json:/device.json:ro \
	-v my-device-storage:/app/storage \
	ghcr.io/pantavisor/pantavisor-mocker:latest \
	start -c /device.json --no-tui

docker logs -f my-device
```

For TLS ownership, mount the cert/key too and reference them from `device.json` with absolute container paths, e.g. `-v ${PWD}/ownership:/ownership:ro` and `"ownership": { "cert": "/ownership/cert.pem", "key": "/ownership/key.pem" }`.

### Swarm: one container per device (recommended)

Each container runs `swarm device`: on first start it provisions **one** device from a shared [`swarm.json`](#swarm-mode-fleet-simulation) (picking a random model and, with `--channel random`, a random channel) and then runs it in the foreground. One device = one container = one log stream, and the fleet size is just the number of replicas.

Using `examples/docker/docker-compose.yaml`:

```yaml
services:
  device:
    image: ghcr.io/pantavisor/pantavisor-mocker:latest
    command: ["swarm", "device", "-c", "/swarm.json", "--channel", "random"]
    volumes:
      - ./swarm.json:/swarm.json:ro
      # - ./ownership:/ownership:ro   # TLS ownership cert.pem/key.pem (optional)
    restart: unless-stopped
    deploy:
      replicas: 5
```

```bash
cd examples/docker            # put your swarm.json next to the compose file
docker compose up -d --scale device=10

docker compose logs -f        # all devices
docker logs -f docker-device-3  # one device
docker compose down           # add -v to also discard the device identities
```

Each container stores its device state in an anonymous per-container volume (`/app/storage`), so identities survive restarts and are dropped when the container is removed. The `generate` and `simulate` blocks of `swarm.json` are not used in this mode — replicas define the fleet.

To validate TLS ownership, put `cert.pem`/`key.pem` in `./ownership/`, uncomment the mount, and add `"ownership": { "cert": "/ownership/cert.pem", "key": "/ownership/key.pem" }` to `swarm.json`; each device copies the pair into its storage on first start.

### Swarm: whole fleet in one container

Alternatively, `swarm run --headless` generates and simulates the entire fleet inside a single container using tmux sessions:

```bash
docker run -d --name my-swarm \
	-v ${PWD}/my-fleet:/workspace \
	ghcr.io/pantavisor/pantavisor-mocker:latest \
	swarm run -d /workspace --headless

docker logs -f my-swarm       # simulation manager output
```

`/workspace` must contain a `swarm.json`; generated devices and `simulation.log` land next to it. This mode is more compact (one container for hundreds of devices) but the per-device output lives in tmux sessions inside the container (`docker exec -it my-swarm tmux attach -t <session>`) rather than in `docker logs` — prefer one-container-per-device when you want container-native logs.

## Running in Kubernetes

Ready-to-apply manifests live in `examples/kubernetes/`. Both are driven by the same `swarm.json`, shipped as a ConfigMap. For real deployments move the `autojoin_token` into a Secret.

For TLS ownership, ship the cert/key as a Secret and mount it at `/ownership` (both manifests carry a commented-out volume/mount for it), then add `"ownership": { "cert": "/ownership/cert.pem", "key": "/ownership/key.pem" }` to the `swarm.json` in the ConfigMap:

```bash
kubectl create secret generic pantavisor-mocker-ownership \
  --from-file=cert.pem=./cert.pem --from-file=key.pem=./key.pem
```

### One pod per device: `swarm-devices.yaml` (recommended)

A StatefulSet where every pod runs `swarm device`: it provisions its own device from the shared config on first start and keeps the identity on its own PersistentVolumeClaim, so restarts and reschedules resume the same registered devices. You get `kubectl logs` per device and scale the fleet with replicas:

```bash
kubectl apply -f examples/kubernetes/swarm-devices.yaml

kubectl scale statefulset pantavisor-mocker-device --replicas=20
kubectl logs -f pantavisor-mocker-device-3      # logs of device #3
kubectl delete -f examples/kubernetes/swarm-devices.yaml   # PVCs (identities) remain unless deleted too
```

### Whole fleet in one pod: `swarm.yaml`

A Deployment running `swarm run -d /workspace --headless`: the pod generates the fleet on first start (into an `emptyDir`, or a PVC if you want identities to survive) and simulates all devices via tmux inside the single container:

```bash
kubectl apply -f examples/kubernetes/swarm.yaml
kubectl logs -f deploy/pantavisor-mocker-swarm  # simulation manager output
```

Use this when you want the smallest footprint; use the StatefulSet when you want per-device pods, logs and lifecycle.

## Build and Installation

### Prerequisites

- **Zig Compiler**: Version **0.15.2** is strictly required.

### 1. Build the project

To build the project, run the following command from the project root:

```bash
zig build -Doptimize=ReleaseSafe
```

The executable will be generated in `zig-out/bin/pantavisor-mocker`.

### 2. Install globally (Optional)

To use `pantavisor-mocker` from anywhere, move the binary to your local bin directory:

```bash
sudo cp zig-out/bin/pantavisor-mocker /usr/local/bin/
```

Alternatively, add the output directory to your `PATH` in your `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="$PATH:$(pwd)/zig-out/bin"
```


#### 1. Initialize Storage
Use the `init` command to create the necessary directory structure and default configuration — either from a [`device.json`](#one-file-device-config-devicejson) or with flags:
```bash
# from a device config file (recommended)
pantavisor-mocker init --storage my_storage -c device.json

# or with flags
pantavisor-mocker init --storage my_storage --token YOUR_AUTO_TOKEN_HERE

# with a TLS ownership cert/key (copied to my_storage/ownership/)
pantavisor-mocker init --storage my_storage --token YOUR_AUTO_TOKEN_HERE --cert cert.pem --key key.pem
```
*If `--storage` is omitted, it defaults to `./storage`. If `--token` is provided, it will be saved to the configuration for automatic registration. `--cert`/`--key` must be given together (see [TLS Ownership Configuration](#tls-ownership-configuration)). You can also skip `init` entirely: `start -c device.json` initializes the storage on first run.*

#### 2. Configure Auto-Token (Manual)
If you didn't provide a token during `init`, you can manually add your Pantahub Auto-Token to `my_storage/config/pantahub.config`:
```properties
PH_FACTORY_AUTOTOK=YOUR_AUTO_TOKEN_HERE
```

#### 3. Run the Mocker
Start the simulation using the initialized storage.
```bash
pantavisor-mocker start --storage my_storage
```

### Automation Mode

The mocker supports an **automation mode** that automatically responds to invitations and update decisions without manual user interaction. This is enabled using the `--auto` flag on the `start` command.

```bash
pantavisor-mocker start --storage my_storage --auto
```

When automation mode is active:
- **Fleet invitations** are automatically accepted, skipped, or deferred based on configured weights
- **Update decisions** are automatically selected (DONE, UPDATED, ERROR, or WONTGO) based on configured weights
- **Mandatory invitations** are always auto-accepted regardless of weights

#### Automation Configuration

Automation behavior can be customized via the `automation` block in `storage/config/mocker.json`:

```json
{
  "automation": {
    "enabled": true,
    "seed": 12345,
    "invitation": {
      "accept": 70,
      "skip": 20,
      "later": 10
    },
    "update": {
      "done": 60,
      "updated": 25,
      "error": 10,
      "wontgo": 5
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `enabled` | Set to `true` to enable automation (can also be enabled via `--auto` flag) |
| `seed` | Optional random seed for reproducible behavior |
| `invitation.accept` | Weight for accepting invitations (default: 100) |
| `invitation.skip` | Weight for skipping invitations (default: 0) |
| `invitation.later` | Weight for deferring invitations (default: 0) |
| `update.done` | Weight for DONE response (default: 100) |
| `update.updated` | Weight for UPDATED response (default: 0) |
| `update.error` | Weight for ERROR response - simulates failure (default: 0) |
| `update.wontgo` | Weight for WONTGO response - rejects update (default: 0) |

**Notes:**
- Weights are relative, not percentages. For example, `{accept: 70, skip: 20, later: 10}` means 70% accept, 20% skip, 10% later.
- The `--auto` CLI flag overrides `automation.enabled` to `true`, even if the config file has it set to `false`.
- If `--auto` is used without an `automation` block in `mocker.json`, default weights are applied (100% accept for invitations, 100% DONE for updates).

### Interactive Updates

When the mocker receives an update from Pantahub, it will proceed through the DOWNLOADING and INPROGRESS states. Once it reaches the TESTING phase, the process will pause and prompt for a manual decision via the terminal:

```
UPDATE DECISION REQUIRED
An update cycle is in TESTING phase.
Select Outcome:
[U]PDATED  - Success (Immediate)
[D]ONE     - Success (Reboot)
[E]RROR    - Simulate Failure
[W]ONTGO   - Reject Update

```

Available Decisions:
u (UPDATED): Simulates an immediate successful update.
d (DONE): Marks the update as successful, typically following a simulated reboot.
e (ERROR): Simulates a failure, triggering the rollback mechanism.
w (WONTGO): Rejects the update entirely.

### Fleet Invitations

The mocker supports the **Fleet Invitation Protocol**, allowing you to simulate user consent for fleet-wide updates.

1. **Trigger**: When Pantahub sets the `fleet.update-proto.token` in **User Metadata** (containing an invitation).
2. **Prompt**: The mocker detects the invitation and pauses to request user input:

```text
*** INVITATION RECEIVED ***
Release: ...
Vendor Release: ...
Deployment: ...
Actions: (a)CCEPT, (s)KIP, ask me (l)ater
```

3. **Actions**:
   - **(a)CCEPT**: Accepts the update. The mocker updates **Device Metadata** with an acceptance token, signaling Pantahub to proceed.
   - **(s)KIP**: Declines the update for this deployment.
   - **ask me (l)ater**: Ignores the invite for now (will prompt again in the next cycle).
   - *Timeout*: Defaults to "Remember Later" if no input is received within 10 seconds.

#### Protocol Specification

The protocol uses the `fleet.update-proto.token` key in metadata. Invitations are posted by the fleet controller in **User Metadata**, and answers are posted by the device in **Device Metadata**.

**Invite (User Metadata)**:
```json
{
   "#spec": "fleet-update-proto@v1",
   "type": "INVITE",
   "deployment": "deployment-id",
   "release": "release-id",
   "vendorRelease": "sap-release-id",
   "earliestUpdate": "DATE",
   "latestUpdate": "DATE",
   "mandatory": "true|false"
}
```

**Accept (Device Metadata)**:
```json
{
   "#spec": "fleet-update-proto@v1",
   "type": "ACCEPT",
   "deployment": "deployment-id",
   "release": "release-id",
   "preferredUpdate": "DATE-TIME|NOW"
}
```

**Skip (Device Metadata)**:
```json
{
   "#spec": "fleet-update-proto@v1",
   "type": "SKIP",
   "deployment": "deployment-id",
   "release": "release-id"
}
```

Other supported message types include `INPROGRESS`, `CANCELED`, `DONE`, `ERROR`, and `ASKAGAIN`.

## pvcontrol Server

The mocker includes a built-in server that replicates the standard Pantavisor control socket (`pv-ctrl`). This allows you to use the standard `pvcontrol` script or any other tool that expects the Pantavisor Control API to interact with the simulated device.

### Socket Location

The control socket is created automatically when the mocker starts and is located at:
`storage/pantavisor/pv-ctrl`

### Usage with `pvcontrol`

You can point the `pvcontrol` script to the mocker's socket using the `-s` option:

```bash
# List simulated containers
./pvcontrol -s storage/pantavisor/pv-ctrl ls

# List simulated groups
./pvcontrol -s storage/pantavisor/pv-ctrl groups ls

# View simulated device metadata
./pvcontrol -s storage/pantavisor/pv-ctrl devmeta ls

# View simulated configuration
./pvcontrol -s storage/pantavisor/pv-ctrl conf ls

# Send a signal
./pvcontrol -s storage/pantavisor/pv-ctrl signal ready

# Simulate a reboot
./pvcontrol -s storage/pantavisor/pv-ctrl cmd reboot
```

### Supported Endpoints

The server implements over 20 endpoints with JSON response signatures that are byte-compatible with a real Pantavisor device, including:
- `GET /containers`, `GET /groups`
- `POST /signal`, `POST /commands` (including reboot/poweroff simulation)
- `GET/PUT/DELETE /device-meta`, `GET/PUT/DELETE /user-meta`
- `GET /buildinfo`
- `GET/PUT /objects`
- `GET/PUT /steps`, `GET /steps/<rev>/progress`
- `GET /config`, `GET /config2`

## Swarm Mode (Fleet Simulation)

Swarm mode lets you generate and manage large fleets of simulated devices from a single workspace. It replaces the `pvmocks` bash script with native Zig subcommands under `pantavisor-mocker swarm`.

### Quick Start

The whole swarm is described by a single `swarm.json` file: Pantahub endpoint, autojoin token, metadata templates, generation counts, automation weights and simulation options.

```bash
# 1. Create a workspace with a swarm.json config template
pantavisor-mocker swarm init --dir my-fleet

# 2. Edit swarm.json (set pantahub.host and pantahub.autojoin_token, adjust channels/models/counts)
vim my-fleet/swarm.json

# 3. Generate (first run only) and simulate everything from that one config
pantavisor-mocker swarm run --dir my-fleet
```

To run the same fleet in containers instead — one device per container/pod with its own log stream — see [Running in Docker](#running-in-docker) and [Running in Kubernetes](#running-in-kubernetes).

Or step by step:

```bash
cd my-fleet

# Generate devices and/or appliances (counts/endpoint come from swarm.json, flags override)
pantavisor-mocker swarm generate-devices --count 10
pantavisor-mocker swarm generate-appliances --count 5

# Check what was generated
pantavisor-mocker swarm status

# Launch all mockers in tmux sessions
pantavisor-mocker swarm simulate

# Or with automation mode (auto-respond to invitations/updates)
pantavisor-mocker swarm simulate --auto

# Clean up when done
pantavisor-mocker swarm clean --target all
```

### Swarm Commands

#### `swarm init [--dir <dir>]`

Creates a workspace directory with a single `swarm.json` configuration template (never overwritten if it exists), plus empty `appliances/` and `devices/` directories.

```bash
pantavisor-mocker swarm init --dir my-fleet
```

`swarm.json` keys:

| Key | Purpose |
|------|---------|
| `pantahub.host` / `pantahub.port` | Pantahub API endpoint written into every generated device (port may be a string or a number) |
| `pantahub.autojoin_token` | Pantahub auto-join token for device registration (required) |
| `group_key` | Metadata key used to group devices |
| `random_keys` | Metadata keys that should receive random numeric values |
| `base` | Base device metadata applied to all generated devices |
| `channels` | Channel definitions with channel-specific metadata overlays |
| `models` | Hardware model names |
| `generate.appliances` / `generate.devices` | Generation counts used by `swarm run` and as the `--count` default |
| `automation` | Automation block copied verbatim into each generated `mocker.json` (see Automation Configuration) |
| `simulate.auto` / `simulate.headless` | Default simulation options used by `swarm run` |
| `ownership.cert` / `ownership.key` | Optional TLS client cert/key (PEM), copied into every provisioned device's `ownership/`; paths are relative to the config file (see [TLS Ownership Configuration](#tls-ownership-configuration)) |

**Legacy layout**: workspaces without `swarm.json` still load the old multi-file layout (`autojointoken.txt`, `group_key.txt`, `base.json`, `channels.json`, `models.txt`, `to_random_keys.txt`). When `swarm.json` exists it takes precedence and the legacy files are ignored. Use `swarm convert` to migrate.

**Multiple configurations per folder**: `init`, `generate-*` and `run` accept `-c, --config <file>` to use a different config file (relative to the workspace, or absolute), so variants like `swarm-stage.json` and `swarm-prod.json` can live side by side:

```bash
pantavisor-mocker swarm init -d my-fleet -c swarm-stage.json
pantavisor-mocker swarm generate-devices -w my-fleet -d my-fleet/devices-stage -c swarm-stage.json
pantavisor-mocker swarm run -d my-fleet -c swarm-stage.json
```

When a config is named explicitly, a missing file is an error (no legacy fallback). Note that `swarm run` always generates into `appliances/`/`devices/` and `simulate` launches every mocker in the workspace regardless of which config generated it — to keep fleets fully separated, generate into distinct output dirs (as above) or use separate workspace directories.

#### `swarm convert [--dir <dir>] [--host <host>] [--port <port>] [--force]`

Converts a legacy multi-file workspace into a single `swarm.json`:

```bash
pantavisor-mocker swarm convert --dir my-old-fleet
```

- The legacy config files are merged into the `swarm.json` schema shown above.
- The Pantahub endpoint and automation block are not stored in the legacy files, so they are recovered from already-generated devices (`pantahub.config` / `mocker.json`) when the workspace has any; `--host`/`--port` override, and the fallback is `api.pantahub.com:443`.
- `generate` counts are inferred from the existing `appliances/` and `devices/` content.
- `-o, --output <file>` writes to a different file name (for keeping several configurations in one folder).
- Refuses to overwrite an existing output file unless `--force` is given. The legacy files are left in place (now ignored) and can be deleted afterwards.

#### `swarm generate-devices --count <N> [options]`

Generates `N` generic simulated devices. Each device gets:
- A random 8-character hex ID
- A `mocker` service directory with standard `pantahub.config` and `mocker.json`
- Merged device metadata from the base metadata + random keys + group key

**Options:**
- `-n, --count <N>`: Number of devices to generate (default: `generate.devices` from `swarm.json`)
- `-d, --dir <dir>`: Output directory (default: `devices`)
- `-w, --workspace <dir>`: Workspace directory containing `swarm.json` or legacy config files (default: `.`)
- `--host <host>`: Pantahub API host (default: `pantahub.host` from `swarm.json`, else `api.pantahub.com`)
- `--port <port>`: Pantahub API port (default: `pantahub.port` from `swarm.json`, else `443`)

```bash
pantavisor-mocker swarm generate-devices --count 50 --host api.pantahub.com --port 443
```

Directory structure:
```
devices/
  a1b2c3d4/
    mocker/
      config/
        pantahub.config
        mocker.json
      ...
```

#### `swarm generate-appliances --count <N> [options]`

Generates `N` appliances **per channel** defined in `channels.json`. Each appliance gets a subdirectory for every model in `models.txt`.

For example, with 2 channels and 2 models, `--count 3` creates `2 × 3 × 2 = 12` mocker instances.

**Options:**
- `-n, --count <N>`: Number of appliances per channel (default: `generate.appliances` from `swarm.json`)
- `-d, --dir <dir>`: Output directory (default: `appliances`)
- `-w, --workspace <dir>`: Workspace directory containing `swarm.json` or legacy config files (default: `.`)
- `--host <host>`: Pantahub API host (default: `pantahub.host` from `swarm.json`, else `api.pantahub.com`)
- `--port <port>`: Pantahub API port (default: `pantahub.port` from `swarm.json`, else `443`)

```bash
pantavisor-mocker swarm generate-appliances --count 3
```

Directory structure:
```
appliances/
  FRIDGE0001/
    a1b2c3d4/
      OrangePi_3_LTS/
        config/
          pantahub.config
          mocker.json
      Raspberry_Pi_3_Model_B_Plus_Rev_1.4/
        config/
          ...
```

Each `mocker.json` contains merged metadata from the base metadata + channel overlay + random values + group key + model name, plus the `automation` block from `swarm.json` (if configured).

#### `swarm run [--dir <dir>] [--auto] [--headless]`

One-shot orchestrator driven entirely by `swarm.json`: generates the fleet if the workspace has no generated content yet, then launches the simulation. This is the command to use for containers/Kubernetes — a pod goes from a single config file to a running swarm:

```bash
pantavisor-mocker swarm run --dir /workspace --headless
```

**Options:**
- `-d, --dir <dir>`: Workspace directory containing `swarm.json` (default: `.`)
- `-c, --config <file>`: Config file to use instead of `swarm.json`
- `-a, --auto`: Force automation mode (overrides `simulate.auto` from `swarm.json`)
- `--headless`: Run without the interactive menu (overrides `simulate.headless`)

Behavior:
- If `generate.appliances` > 0 and `appliances/` is empty, runs `generate-appliances`; same for `generate.devices` and `devices/`. Existing content is never regenerated, so device identities survive restarts when the workspace is on a persistent volume.
- Simulation options default to the `simulate` block in `swarm.json`; CLI flags force them on.

See `examples/kubernetes/swarm.yaml` for a ready-to-apply ConfigMap + Deployment that mounts `swarm.json` into a writable workspace and runs `swarm run --headless`.

#### `swarm device [--config <file>] [--storage <dir>] [options]`

Runs a **single** swarm member as its own foreground process — the one-device-per-container entrypoint (see [Running in Docker](#running-in-docker) / [Running in Kubernetes](#running-in-kubernetes)). On first start it provisions one device from the swarm config (device id, merged metadata, automation block, endpoint) into the storage directory; later starts detect the existing identity and just run it:

```bash
pantavisor-mocker swarm device -c my-fleet/swarm.json -s device1-storage --channel random
```

**Options:**
- `-c, --config <file>`: Path to the swarm config JSON (default: `swarm.json`)
- `-s, --storage <dir>`: Storage directory for this device's identity and state (default: `storage`)
- `--channel <name|random>`: Apply a channel overlay from the config — a specific channel, or a random one. Omit for a generic device.
- `--model <name>`: Model name (default: picked at random from the config's `models`)
- `-a, --auto`, `--debug`, `--one-shot`: Same as `start`

Runs with the plain stdout renderer (no TUI), so logs go to the container runtime. The `generate` and `simulate` blocks of `swarm.json` are ignored — the number of running `swarm device` instances *is* the fleet.

#### `swarm simulate [--dir <dir>] [--auto] [--headless]`

Scans the workspace for all generated `mocker.json` files and launches each one in a separate tmux session.

```bash
pantavisor-mocker swarm simulate
```

**Options:**
- `-d, --dir <dir>`: Workspace directory (default: `.`)
- `-a, --auto`: Enable automation mode for all simulated devices (passes `--auto` to each mocker instance)
- `--headless`: Run without the interactive menu — monitors the tmux sessions, logs state changes to `simulation.log`, and exits when all sessions have stopped or on `SIGTERM`/`SIGINT` (killing all sessions). Use this in containers where no TTY is attached.

```bash
# Launch all mockers with automation enabled
pantavisor-mocker swarm simulate --auto
```

When `--auto` is used, each simulated device will automatically respond to invitations and updates based on its `mocker.json` automation configuration (or defaults if not configured). This is useful for large-scale fleet testing without manual intervention.

Presents an interactive menu:
```
==========================================
   Pantavisor Mocker Simulation Manager
==========================================
#   | Tmux Session                        | Path
----|------------------------------------|---------------------------------
0   | a1b2c3d4_mocker                     | [RUNNING] devices/a1b2c3d4/mocker
1   | e5f6a7b8_OrangePi_3_LTS             | [RUNNING] appliances/OrangePi/e5f6a7b8/OrangePi_3_LTS
------------------------------------------
Enter index number or session name to attach.
q to Quit (terminates all)
==========================================
Select >
```

- Enter a number or session name to attach to a tmux session
- Press `Ctrl+B` then `D` to detach and return to the menu
- Press `q` to quit and terminate all sessions

**Requires**: `tmux` must be installed.

#### `swarm status [--dir <dir>]`

Shows the current workspace status: number of generated mockers and config file presence.

```bash
pantavisor-mocker swarm status
```

```
swarm workspace status
========================
Appliance mockers: 12
Device mockers:    50

Config files:
  [OK] swarm.json
  [--] autojointoken.txt (missing)
  [--] group_key.txt (missing)
  [--] base.json (missing)
  [--] channels.json (missing)
  [--] models.txt (missing)
  [--] to_random_keys.txt (missing)
```

(The legacy files are only needed when `swarm.json` is absent.)

#### `swarm clean [--target <appliances|devices|all>] [--dir <dir>]`

Removes generated device/appliance directories. Config template files are preserved.

```bash
# Remove only devices
pantavisor-mocker swarm clean --target devices

# Remove only appliances
pantavisor-mocker swarm clean --target appliances

# Remove everything (default)
pantavisor-mocker swarm clean --target all
```

### Legacy Workspace Files

Before `swarm.json`, a workspace was described by six separate files: `autojointoken.txt`, `group_key.txt`, `base.json` (base metadata for all devices), `channels.json` (channel overlays), `models.txt` (one model per line) and `to_random_keys.txt` (keys that get random values). They still load when no `swarm.json` is present, and map 1:1 onto the `swarm.json` keys shown above — run [`swarm convert`](#swarm-convert---dir-dir---host-host---port-port---force) to migrate a workspace to the single-file format.

## Architecture

This project follows a multi-threaded, message-based architecture designed for scalability and testability. The system is composed of independent subsystems that communicate through a central router using Unix domain sockets and JSON messages.

### Core Components

#### 1. **Router** (`src/core/router.zig`)
- Central IPC message broker running on a Unix domain socket
- Manages subsystem lifecycle (registration, message routing, shutdown)
- Handles up to 64 concurrent connections
- Routes messages between subsystems based on `SubsystemId`

#### 2. **Background Job / Mocker** (`src/core/mocker.zig`)
- Main business logic coordinator
- Runs the primary event loop for:
  - Device registration and authentication
  - Metadata synchronization (device ↔ Pantahub)
  - Update flow processing (download, install, test)
  - Fleet invitation handling
- Coordinates with Router via IPC client
- Manages pvcontrol server for Pantavisor Control API

#### 3. **Logger Subsystem** (`src/core/logger_subsystem.zig`)
- Buffers log messages from all subsystems
- Persists logs to local storage (`storage/logs/`)
- Periodically uploads logs to Pantahub
- Thread-safe log buffering with mutex protection

#### 4. **Renderer** (`src/ui/`)
- **TUI Renderer** (`src/ui/tui_renderer.zig`): Vaxis-based terminal UI
- **StdInOut Renderer** (`src/ui/stdinout_renderer.zig`): Fallback CLI interface
- Displays system state, progress, and invitations
- Collects user input for update decisions and invitations

#### 5. **pvcontrol Server** (`src/core/pvcontrol_server.zig`)
- Implements Pantavisor Control API on Unix socket
- Provides compatibility layer for `pvcontrol` CLI tool
- Endpoints: containers, groups, metadata, objects, steps, config, etc.

### Subsystems & Communication

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLI Entry Point                          │
│                     (src/main.zig + cli/)                       │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ initializes
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Router (IPC Hub)                        │
│                    (src/core/router.zig)                        │
│                                                                  │
│  Unix Socket: storage/mocker.sock                               │
│  Routes JSON messages between subsystems                        │
└────────┬───────────────┬───────────────┬────────────────────────┘
         │               │               │
         │               │               │
         ▼               ▼               ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────────────────────┐
│   Renderer   │  │    Logger    │  │    Background Job (Mocker)   │
│              │  │              │  │                              │
│ - TUI Mode   │  │ - Buffer     │  │  ┌────────────────────────┐  │
│ - StdIO Mode │  │ - Persist    │  │  │  Main Event Loop       │  │
│              │  │ - Upload     │  │  │                        │  │
│ User Input:  │  │              │  │  │  - Registration        │  │
│  - Update    │◄─┤              │  │  │  - Metadata Sync       │  │
│  - Invite    │  │              │  │  │  - Update Flow         │  │
└──────────────┘  └──────────────┘  │  │  - Invitations         │  │
                                    │  └──────────┬─────────────┘  │
                                    │             │                │
                                    │             ▼                │
                                    │  ┌────────────────────────┐  │
                                    │  │   pvcontrol Server     │  │
                                    │  │  (Unix Socket Server)  │  │
                                    │  │                        │  │
                                    │  │  Compatible with       │  │
                                    │  │  pvcontrol CLI         │  │
                                    │  └────────────────────────┘  │
                                    └──────────────────────────────┘
```

### Message Flow Architecture

```
SubsystemId: [core, renderer, logger, background_job]

MessageType:
  Control:
    - subsystem_init
    - subsystem_start
    - subsystem_stop
    - subsystem_ready

  Application:
    - log_message           (any → logger)
    - render_log            (any → renderer)
    - render_update         (background_job → renderer)
    - render_invite         (background_job → renderer)
    - get_user_input        (background_job → renderer)
    - sync_progress         (background_job → renderer)
    - invitation_required   (background_job → core)
    - update_required       (background_job → core)
    - user_response         (renderer → background_job)

  Response:
    - response_ok
    - response_error
    - user_decision
```

### Data Flow Examples

#### Update Flow
```
1. Background Job detects update from Pantahub
   └─► Message: update_required (to: core)
   
2. Background Job downloads & installs
   └─► Message: render_update (to: renderer)
   └─► Message: sync_progress (to: renderer)
   
3. Update reaches TESTING phase
   └─► Message: get_user_input (to: renderer)
   
4. User makes decision (Pass/Fail)
   └─► Message: user_decision (to: background_job)
   
5. Background Job proceeds or rolls back
   └─► Message: render_state_change (to: renderer)
```

#### Fleet Invitation Flow
```
1. Background Job detects invitation in User Metadata
   └─► Message: invitation_required (to: core)
   
2. Renderer prompts user
   └─► Message: render_invite (to: renderer)
   └─► Message: get_user_input (to: renderer)
   
3. User accepts/skips
   └─► Message: user_decision (to: background_job)
   
4. Background Job posts response to Device Metadata
   └─► Message: sync_progress (to: renderer)
```

### Key Modules

| Module | Path | Purpose |
|--------|------|---------|
| **Router** | `src/core/router.zig` | IPC message routing, subsystem management |
| **Mocker** | `src/core/mocker.zig` | Main coordinator, event loop |
| **Background Job** | `src/core/background_job.zig` | Subsystem wrapper for Mocker |
| **Logger Subsystem** | `src/core/logger_subsystem.zig` | Log buffering & upload |
| **IPC** | `src/core/ipc.zig` | IPC client/server implementation |
| **Messages** | `src/core/messages.zig` | JSON message definitions |
| **Config** | `src/core/config.zig` | Configuration management |
| **Local Store** | `src/core/local_store.zig` | File system operations |
| **Business Logic** | `src/core/business_logic.zig` | Update/validation algorithms |
| **Update Flow** | `src/flows/update_flow.zig` | OTA update state machine |
| **Invitation** | `src/flows/invitation.zig` | Fleet invitation protocol |
| **Client** | `src/net/client.zig` | Pantahub API client |
| **pvcontrol Server** | `src/core/pvcontrol_server.zig` | Pantavisor Control API server |

### Thread Model

```
Main Thread
├─ CLI Framework (command parsing)
└─ Renderer (blocking UI loop)
    ├─ TUI Renderer: Vaxis event loop
    └─ StdIO Renderer: stdin polling

Router Thread
└─ Unix socket accept loop
    └─ Spawns detached threads for each connection

Logger Thread
├─ IPC receive loop (from Router)
├─ Flush loop (periodic buffer write)
└─ Upload loop (periodic cloud push)

Background Job Thread
├─ IPC receive loop (from Router)
└─ Main event loop
    ├─ Registration check
    ├─ Metadata sync (timed intervals)
    ├─ Update detection & processing
    └─ Invitation handling

pvcontrol Thread
└─ Unix socket server (pv-ctrl socket)
    └─ Spawns threads for each pvcontrol connection
```

### Communication Protocol

All inter-subsystem communication uses JSON messages over Unix domain sockets:

```json
{
  "from": "background_job",
  "to": "renderer",
  "type": "render_update",
  "data": {
    "percentage": 75,
    "details": "Downloading objects..."
  }
}
```

Messages are serialized/deserialized using Zig's `std.json` module and transmitted as length-prefixed frames for reliable parsing.
