# Pantavisor Mocker

Pantavisor Mocker is a tool designed to mock the functionality of [Pantavisor](https://pantavisor.io/) and how it interacts with [Pantahub](https://api.pantahub.com). It allows you to simulate core device operations—such as registration, metadata synchronization, and OTA (Over-The-Air) update flows—without requiring actual hardware or a full Pantavisor runtime.

## What is Pantavisor?

[Pantavisor](https://pantavisor.io/) is a framework for building embedded Linux systems using lightweight Linux Containers (LXC). It turns the entire userland, including the OS, networking, and applications, into modular, portable, and manageable building blocks.

Pantavisor Mocker specifically simulates the **Pantavisor Runtime** behavior regarding:

- **State JSON**: A declarative description of the system state, defining the set of containers, BSPs, and configurations that should be running.
- **Trails & Revisions**: The history of state changes. Every update creates a new immutable **Revision**, forming a **Trail**.
- **Objects**: The content-addressable artifacts (container images, firmware, configs) that make up a revision.
- **Update Lifecycle**: The atomic transition from one revision to another, including download, verification, installation, testing, and potential rollback.

## Features

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
- **Fleet Invitation Protocol**: Simulates user consent flows (Accept/Skip) for managed fleet updates.
- **TLS Ownership Validation**: Supports device ownership verification using client-side TLS certificates.

## Configuration

The application state and configuration are stored in the `storage/` directory.

### Main Configuration: `storage/config/pantahub.config`

This file contains the core connectivity and credential settings. Key parameters include:

- `PH_CREDS_HOST`: Pantahub API host (default: `api.pantahub.com`).
- `PH_CREDS_PORT`: API port (default: `443`).
- `PH_CREDS_PRN`: The Device ID (PRN). Populated automatically after registration.
- `PH_CREDS_SECRET`: The Device Secret. Populated automatically after registration.
- `PH_FACTORY_AUTOTOK`: The auto-token used for initial device registration (required for new devices).
- `PH_METADATA_DEVMETA_INTERVAL`: Interval (in seconds) to push device metadata.
- `PH_METADATA_USRMETA_INTERVAL`: Interval (in seconds) to pull user metadata.

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

To simulate a device that proves its ownership via TLS client certificates:

1. Create a directory named `ownership` inside your storage directory (e.g., `storage/ownership/`).
2. Place your client certificate and private key in this directory:
   - `storage/ownership/cert.pem`
   - `storage/ownership/key.pem`

When the mocker starts, if these files exist and the device has not yet been verified (indicated by `ovmode_status` in device metadata), the mocker will:
1. Authenticate with Pantahub to obtain a temporary token.
2. Call the ownership validation endpoint using the provided TLS certificate and key.
3. Upon success, update the local device metadata (`ovmode_status: completed`) and proceed with normal operation.

## Usage

Once installed or added to your PATH, you can use the `pantavisor-mocker` command.

### Docker Usage

You can run the mocker using the pre-built Docker image from the GitHub Container Registry.

#### 1. Initialize Storage with Docker
```bash
docker run -it -v ${PWD}/storage:/app/storage \
	--name pantavisor \
	ghcr.io/pantavisor/pantavisor-mocker:latest \
	init --token YOUR_AUTO_TOKEN_HERE
```

#### 2. Run the Mocker with Docker
```bash
docker run -it \
	-v ${PWD}/storage:/app/storage \
	--name pantavisor \
	ghcr.io/pantavisor/pantavisor-mocker:latest \
 start
```

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
Use the `init` command to create the necessary directory structure and default configuration. You can optionally provide a Pantahub Auto-Token during initialization.
```bash
pantavisor-mocker init --storage my_storage --token YOUR_AUTO_TOKEN_HERE
```
*If `--storage` is omitted, it defaults to `./storage`. If `--token` is provided, it will be saved to the configuration for automatic registration.*

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

```bash
# 1. Create a workspace with template config files
pantavisor-mocker swarm init --dir my-fleet

# 2. Edit config files (set your real token, adjust channels/models)
cd my-fleet
vim autojointoken.txt

# 3. Generate devices and/or appliances
pantavisor-mocker swarm generate-devices --count 10
pantavisor-mocker swarm generate-appliances --count 5

# 4. Check what was generated
pantavisor-mocker swarm status

# 5. Launch all mockers in tmux sessions
pantavisor-mocker swarm simulate

# 6. Clean up when done
pantavisor-mocker swarm clean --target all
```

### Swarm Commands

#### `swarm init [--dir <dir>]`

Creates a workspace directory with template configuration files. Existing files are never overwritten.

```bash
pantavisor-mocker swarm init --dir my-fleet
```

Generated template files:

| File | Purpose |
|------|---------|
| `autojointoken.txt` | Pantahub auto-join token for device registration |
| `group_key.txt` | Metadata key used to group devices (default: `pantavisor.uname.node.name`) |
| `base.json` | Base device metadata applied to all generated devices |
| `channels.json` | Channel definitions with channel-specific metadata overlays |
| `models.txt` | Hardware model names (one per line) |
| `to_random_keys.txt` | Metadata keys that should receive random numeric values |

Also creates empty `appliances/` and `devices/` directories.

#### `swarm generate-devices --count <N> [options]`

Generates `N` generic simulated devices. Each device gets:
- A random 8-character hex ID
- A `mocker` service directory with standard `pantahub.config` and `mocker.json`
- Merged device metadata from `base.json` + random keys + group key

**Options:**
- `-n, --count <N>`: Number of devices to generate (required)
- `-d, --dir <dir>`: Output directory (default: `devices`)
- `-w, --workspace <dir>`: Workspace directory containing config files (default: `.`)
- `--host <host>`: Pantahub API host (default: `api.pantahub.com`)
- `--port <port>`: Pantahub API port (default: `443`)

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
- `-n, --count <N>`: Number of appliances per channel (required)
- `-d, --dir <dir>`: Output directory (default: `appliances`)
- `-w, --workspace <dir>`: Workspace directory containing config files (default: `.`)
- `--host <host>`: Pantahub API host (default: `api.pantahub.com`)
- `--port <port>`: Pantahub API port (default: `443`)

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

Each `mocker.json` contains merged metadata from `base.json` + channel overlay + random values + group key + model name.

#### `swarm simulate [--dir <dir>]`

Scans the workspace for all generated `mocker.json` files and launches each one in a separate tmux session.

```bash
pantavisor-mocker swarm simulate
```

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
  [OK] autojointoken.txt
  [OK] group_key.txt
  [OK] base.json
  [OK] channels.json
  [OK] models.txt
  [OK] to_random_keys.txt
```

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

### Workspace Configuration Files

#### `base.json`

Base metadata applied to **all** generated devices and appliances:

```json
{
  "pantavisor.arch": "aarch64/64/EL",
  "pantavisor.uname.kernel.name": "Linux",
  "pantavisor.uname.machine": "aarch64"
}
```

#### `channels.json`

Defines named channels with metadata overlays. Used by `generate-appliances`:

```json
{
  "FRIDGE0001": {
    "pantavisor.appliance.serialnumber": "FRIDGE0001"
  }
}
```

#### `to_random_keys.txt`

Metadata keys listed here receive a unique random numeric value per device/appliance:

```
pvmocks.random_key
```

#### `group_key.txt`

The metadata key whose value is set to the device/appliance hex ID, useful for grouping:

```
pantavisor.uname.node.name
```

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
