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

You can also run the mocker using the pre-built Docker image from the GitLab Container Registry.

#### 1. Initialize Storage with Docker
```bash
docker run -it -v ${PWD}/storage:/app/storage \
	--name pantavisor \
	registry.gitlab.com/pantacor/pantavisor-runtime/pantavisor-mocker:main \
	init --token YOUR_AUTO_TOKEN_HERE
```

#### 2. Run the Mocker with Docker
```bash
docker run -it \
	-v ${PWD}/storage:/app/storage \
	--name pantavisor \
	registry.gitlab.com/pantacor/pantavisor-runtime/pantavisor-mocker:main \
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

When the mocker receives an update from Pantahub, it will proceed through the `DOWNLOADING` and `INPROGRESS` states. Once it reaches `TESTING`, it will pause and prompt for user input:

```text
INPUT REQUIRED: Press 'p' to PASS or 'f' to FAIL the update (10s timeout defaults to PASS):
```

- Press **`p`** (or wait) to simulate a successful update (`DONE`).
- Press **`f`** to simulate a failure, triggering a rollback (`ERROR` -> Rollback).

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

#### Manual Testing

You can manually trigger an invitation using `pvr`:

```bash
# Set invitation in user-meta
pvr dev set $DEVICE_ID fleet.update-proto.token='{
   "#spec": "fleet-update-proto@v1",
   "type": "INVITE",
   "deployment": "my-deployment",
   "release": "my-release",
   "mandatory": "false"
}'
```

The device's response can be verified in device-meta:
```bash
# Get device-meta answer
pvcontrol devmeta save fleet.update-proto.token ...
```

## Architecture

This project follows a multi-threaded, message-based architecture designed for scalability and testability.

- **Core Router**: Manages subsystem lifecycles and routes messages between them using Unix domain sockets.
- **Subsystems**:
  - **Renderer**: Handles user interaction (TUI or StdInOut).
  - **Logger**: Handles log buffering, file I/O, and cloud uploads.
  - **Background Job (Mocker)**: Handles core business logic (sync, updates, invitations).
- **Communication**: Subsystems communicate via JSON messages over IPC.

For detailed architectural documentation, refer to `plan.md`.
