/// Constants used throughout the Pantavisor Mocker application
///
/// VALIDATION RULES:
/// - Hostnames: Must match DNS naming conventions (alphanumeric, dots, hyphens)
/// - Ports: Must be 1-65535 (valid TCP/UDP port range)
/// - URLs: Must have scheme (http/https), valid host, valid port
/// - SHA256: Must be exactly 64 hexadecimal characters
/// - File paths: Must not contain path traversal sequences (..)
/// - Revisions: Must be positive integers
/// - Deployments: Alphanumeric with hyphens allowed
///
/// STORAGE HIERARCHY:
/// storage/
///   ├── trails/
///   │   ├── 0/
///   │   │   ├── state.json         (update state)
///   │   │   └── .pv/
///   │   │       ├── progress       (progress tracking)
///   │   │       └── log            (operation logs)
///   │   └── N/                     (per-revision data)
///   ├── device-meta/
///   │   └── meta.json              (device metadata)
///   ├── user-meta/
///   │   └── meta.json              (cloud metadata)
///   ├── objects/                   (cached binary objects)
///   ├── current -> trails/0/       (symlink to stable revision)
///   └── current-try -> trails/N/   (symlink to in-progress revision)

// Boot State and Progress JSON payloads
/// Initial boot state JSON for pantavisor service system
/// Format: JSON following pantavisor-service-system@1 spec
pub const BOOT_STATE_JSON = "{\"#spec\":\"pantavisor-service-system@1\"}";
/// Initial progress JSON for factory boot
/// Status: DONE (100%), Ready for operation
pub const BOOT_PROGRESS_JSON = "{\"status\":\"DONE\",\"status-msg\":\"Factory revision\",\"progress\":100,\"retries\":0}";

// Default Configuration Values
/// Default storage base directory for device metadata and revision tracking
pub const DEFAULT_STORAGE_PATH = "storage";
/// Default HTTPS port if not specified in configuration
pub const DEFAULT_PANTAHUB_PORT = "443";

// Timeout and Interval Constants (in milliseconds)
/// Timeout for user invitation decision (10 seconds for UI response)
/// Range: 1000-30000 ms (1-30 seconds)
pub const INVITATION_DECISION_TIMEOUT_MS = 10000;
/// Timeout for generic user response (10 seconds)
pub const USER_RESPONSE_TIMEOUT_MS = 10000;
/// Polling interval for progress file updates (1 second)
/// Range: 100-5000 ms (prevents excessive I/O while staying responsive)
pub const PROGRESS_CHECK_INTERVAL_MS = 1000;
/// Main event loop polling interval (100 ms)
/// Range: 50-500 ms (balance between responsiveness and CPU usage)
pub const EVENT_LOOP_POLL_INTERVAL_MS = 100;

// File System Constants
/// Directory prefix for storing per-revision data (POSIX: trails)
pub const REVISION_DIR_PREFIX = "trails";
/// Per-revision state file containing update/boot metadata
pub const REVISION_STATE_FILENAME = "state.json";
/// Per-revision progress tracking file path
pub const REVISION_PROGRESS_FILENAME = ".pv/progress";
/// Per-revision operation log file path
pub const REVISION_LOG_FILENAME = ".pv/log";
/// Directory containing device metadata (local and cloud-synced)
pub const DEVICE_META_DIR = "device-meta";
/// Device metadata JSON filename (Pantahub device properties)
pub const DEVICE_META_FILENAME = "meta.json";
/// Cache directory for downloaded/cached binary objects
pub const OBJECT_CACHE_DIR = "objects";
/// Symlink to current stable/booted revision (points to trails/X)
pub const CURRENT_SYMLINK = "current";
/// Symlink to revision currently being tested (points to trails/X)
pub const CURRENT_TRY_SYMLINK = "current-try";

// API Constants (Pantahub REST endpoints)
/// Device info endpoint: GET /devices/{device_id}/info
pub const API_DEVICE_INFO_ENDPOINT = "/devices/{s}/info";
/// Trail creation endpoint: POST /trails (creates update history)
pub const API_TRAIL_CREATE_ENDPOINT = "/trails";
/// Trail endpoint: GET /trails/{trail_id} (retrieve trail metadata)
pub const API_TRAIL_ENDPOINT = "/trails/{s}";
/// Specific step in trail: GET /trails/{trail_id}/steps/{revision}
pub const API_STEP_ENDPOINT = "/trails/{s}/steps/{d}";
/// Step binary objects: GET /trails/{trail_id}/objects (download payloads)
pub const API_STEP_OBJECTS_ENDPOINT = "/trails/{s}/objects";
/// Ownership validation: POST /devices/{device_id}/ownership/validate
pub const API_OWNERSHIP_VALIDATE_ENDPOINT = "/devices/{s}/ownership/validate";

// Device Meta Constants
/// Metadata key for over-the-air mode status
pub const OVMODE_STATUS_KEY = "ovmode_status";
/// OTA mode status value: operation completed successfully
pub const OVMODE_STATUS_COMPLETED = "completed";

// Progress Values
pub const PROGRESS_QUEUED = 0;
pub const PROGRESS_DOWNLOADING = 10;
pub const PROGRESS_DOWNLOADED = 50;
pub const PROGRESS_APPLIED = 60;
pub const PROGRESS_TESTING = 75;
pub const PROGRESS_REBOOTING = 80;
pub const PROGRESS_COMPLETE = 100;

// File I/O Constants
pub const FILE_BUFFER_SIZE = 4096;
pub const MAX_JSON_SIZE = 100 * 1024; // 100 KB
pub const SHA256_HEX_LENGTH = 64;

// HTTP Header Constants
pub const CONTENT_TYPE_JSON = "Content-Type: application/json";
pub const CONTENT_TYPE_TEXT_PLAIN = "Content-Type: text/plain";

// Log Constants
pub const LOG_SOURCE = "/pantavisor.log";
pub const LOG_PLATFORM = "pantavisor";
pub const LOG_LEVEL_INFO = "INFO";
pub const MAX_LOG_ENTRIES_PER_PUSH = 100;
pub const LOG_READ_BATCH_SIZE = 4096;

// Thread and Concurrency Constants
pub const REBOOT_SIMULATION_DURATION_S = 10;
pub const STDIN_POLL_TIMEOUT_S = 10;

// Directory Permission Constants (for file creation)
pub const REVISION_BOOTSTRAP_STATE = "0";
pub const DEFAULT_DEVMETA_INTERVAL_S = 30;
