# SystemMetrics — Design Spec

Date: 2026-10-16
Status: Draft, awaiting review — revised 2026-10-16 to match the code at 66ce8c6 (see §11 Revisions; changed lines are marked *[rev]*)

## 1. Goal

A lightweight native macOS menu bar app that shows live system metrics — CPU, RAM, GPU, swap,
internal and external disks, and Docker resource usage — in an iOS-inspired panel that drops
down when the pointer hovers over the menu bar item.

### Success criteria

- All metrics listed in §4 visible in one panel without opening any other app.
- Panel opens on hover after a deliberate 300 ms delay and feels native (material, SF Pro,
  SF Symbols). *[rev R1]*
- Idle cost of the app itself: < 1% CPU, < 60 MB RAM (measured with Instruments).
- Runs on any Apple Silicon Mac with macOS 14+ without extra installs or admin rights.

### Non-goals (v1)

- CPU/GPU temperatures and fan speeds (need private SMC APIs or root).
- Intel Macs.
- Persistent history (only last ~5 minutes in memory).
- Controlling Docker (start/stop) — the app is read-only.
- Mac App Store distribution.

## 2. Distribution

- Target: Developer ID signed + notarized `.app` in a DMG, shared with a team / acquaintances.
  *[rev R9]* Not available yet: until a Developer ID-signed release exists, the app is built
  from source only. User-facing docs must not tell anyone to remove quarantine or bypass
  Gatekeeper.
- No App Sandbox (required for Docker socket and IOKit access). Hardened Runtime on.
- Dependency: an Apple Developer account for signing/notarization.
- Minimum: macOS 14.0, arm64 only.
- Source: https://github.com/serhadtekkol/systemmetrics — commits authored as `serhadtekkol`.

## 3. Architecture

```
SystemMetricsApp (AppKit lifecycle, LSUIElement — no Dock icon)
├── StatusItemController   NSStatusItem + NSTrackingArea, hover/click state machine
├── PanelController        borderless NSPanel hosting SwiftUI, positioned under the item
├── MetricsEngine          @Observable, timer-driven, owns all samplers
│   ├── CPUSampler         host_processor_info: total + per core, P/E clusters
│   ├── MemorySampler      host_statistics64: used / wired / compressed / app, pressure
│   ├── SwapSampler        sysctl vm.swapusage
│   ├── GPUSampler         IOKit IOAccelerator → PerformanceStatistics (util %, memory)
│   ├── DiskSampler        mounted volumes (capacity/free), IOBlockStorageDriver stats
│   │                      (read/write throughput), internal vs external, DiskArbitration
│   │                      notifications for mount/unmount
│   └── DockerSampler      Docker Engine API over unix socket (async, separate cadence)
├── History                fixed-size ring buffer per series (~5 min)
└── UI (SwiftUI)
    ├── MenuBarLabel       icon + "CPU 23% RAM 61%"
    ├── PanelView          card grid
    └── SettingsView       refresh interval, launch at login, menu bar content
```

### Units and interfaces

- Each sampler conforms to a small protocol and is split into:
  - a **source** (thin wrapper over the system call, returns raw values), and
  - a **pure calculation** (raw values → snapshot), testable with fake sources.
- `MetricsEngine` publishes one immutable `SystemSnapshot` per tick; the UI only reads it.
- `UnixSocketHTTPClient` is a minimal HTTP/1.0 GET-only client over a unix domain socket
  (no `docker` CLI). *[rev R8]* Socket discovery (`DockerLocator`), first existing socket wins:
  1. `$DOCKER_HOST`, `unix://` only (TCP ignored).
  2. Docker CLI context: `$DOCKER_CONTEXT`, else `currentContext` from `<config>/config.json`
     (`<config>` = `$DOCKER_CONFIG` or `~/.docker`), resolved through
     `<config>/contexts/meta/<sha256(name)>/meta.json` → `Endpoints.docker.Host` (unix only).
     `default` falls through to step 3.
  3. Known runtime sockets, in order: `~/.docker/run/docker.sock` (Docker Desktop),
     `~/.orbstack/run/docker.sock` (OrbStack), `~/.colima/default/docker.sock`,
     `~/.colima/docker.sock` (Colima), `~/.rd/docker.sock` (Rancher Desktop),
     `/var/run/docker.sock`.

  A GUI / login-item launch does not inherit the shell environment, which is why the context
  and the known paths matter more than `DOCKER_HOST`.
  Endpoints used: `GET /_ping`, `GET /containers/json`,
  `GET /containers/{id}/stats?stream=false&one-shot=true` (at most 30 containers per sample),
  `GET /system/df`, `GET /info`.

### Sampling cadence

| Data | Panel closed | Panel open |
|---|---|---|
| CPU, RAM (menu bar values) | every refresh interval | every refresh interval |
| GPU, swap, disk throughput | not sampled | every refresh interval |
| Disk capacity | not sampled | every refresh interval + on mount/unmount |
| Docker containers / stats | not sampled | every 4 s |
| Docker `system/df` | not sampled | every 30 s |
| Docker `/info` (VM vCPUs, memory) | not sampled | every 60 s |

Refresh interval: 1 / 2 / 5 s (default 2 s).

## 4. Menu bar and panel behaviour

### Menu bar item

- SF Symbol icon + `CPU 23%  RAM 61%`, monospaced digits so width does not jitter.
- Settings can reduce it to icon only, or CPU only / RAM only.

### Hover / click state machine

- Pointer enters the item → after 300 ms the panel opens below it. *[rev R1]*
- Pointer stays inside item or panel → panel stays open.
- Pointer leaves both → panel closes after 500 ms. *[rev R1]*
- Click on the item → panel is **pinned** (stays open regardless of pointer); click again or
  Esc to close. Pinned mode is also the keyboard-accessible path.
- A mouse-down outside the panel closes it in **both** hover and pinned mode; so do a Space
  change and, while pinned, the app losing focus. *[rev R2]*
- Right-click (or Control-click) on the item opens a menu with `Ayarlar…` and
  `SystemMetrics'ten Çık`. There is no quit button in the panel header. *[rev R3]*
- Panel never steals focus from the frontmost app unless pinned.

### Panel layout (~360 pt wide)

- Background `.ultraThinMaterial`, 20 pt corner radius, iOS Control Center style cards.
- Header: Mac model + chip, uptime, settings button.
- Cards:
  - **CPU** — ring gauge, P/E core bars, 5-min sparkline.
  - **RAM** — ring gauge, used/total GB, memory pressure (normal / warning / critical).
    Ring and sparkline colour follow memory pressure, not used %. *[rev R5]*
  - **GPU** — ring gauge (utilization), GPU memory in use, 5-min sparkline.
  - **Swap** — used bytes, allocated size ("ayrılan") as context, compressed memory. No
    percentage and no fill bar: macOS grows swap on demand, so the total is not a ceiling.
    *[rev R4]*
  - **Disks** — one row per volume: internal and external (icon distinguishes them),
    used/total bar, read/write throughput. External rows animate in/out on mount/unmount.
    With no external disk attached, only the internal volume row is shown.
    Only local volumes (`/` and `/Volumes/*`, `MNT_LOCAL`, browsable) are listed; network
    volumes (SMB, NFS, AFP, WebDAV) are skipped so a dead server cannot block sampling.
    Throughput belongs to the physical device and is shown once per device. *[rev R7]*
  - **Docker** — status pill (running / not running), totals: container CPU in vCPUs of the
    Docker VM (`0,8 / 8 vCPU`, VM size from `/info` `NCPU`), container RAM as usage −
    `inactive_file` like `docker stats` (`/ 7,3 GB VM` from `MemTotal`), disk (image layers +
    volumes + build cache + container writable layers); container list sorted by RAM (max 6
    rows, name, CPU % of one vCPU, RAM). *[rev R6]* Hidden entirely if Docker is not installed
    (no socket and none of Docker.app, OrbStack.app, Rancher Desktop.app, `docker` or `colima`
    in `/usr/local/bin` / `/opt/homebrew/bin`). *[rev R8]*
- Panel scrolls if taller than the available screen height.

### Visual language

- SF Pro, SF Symbols, `monospacedDigit` for numbers, Swift Charts for sparklines.
- Load colors: 0–60% green, 60–85% orange, >85% red (system colors).
- Automatic light/dark; contrast checked in both.
- VoiceOver labels on every card; Reduce Motion disables animations.

## 5. Error handling

- Samplers return `Result`; a failed metric shows "—" and "veri yok" only on its own card.
- Docker: socket re-probed every 10 s; card recovers automatically when Docker starts.
- Docker requests time out after 2 s and never block other samplers.
- A volume unmounted mid-read is dropped silently.
- History is a fixed-size ring buffer: memory does not grow over time.

## 6. Settings

- Refresh interval: 1 / 2 / 5 s.
- Launch at login (`SMAppService.mainApp`).
- Menu bar content: icon + CPU + RAM (default) / icon only / CPU only / RAM only.
- Stored in `UserDefaults`.

## 7. Testing

- **Unit (CI):** CPU tick-delta → %, memory page math, swapusage parsing, Docker JSON
  decoding (containers, stats CPU % formula, system/df), ring buffer, hover state machine.
- **Integration (local):** each real sampler returns sane values (CPU 0–100, RAM total =
  physical memory, at least one internal volume).
- **Docker:** both "running" and "not running / not installed" scenarios.
- **Manual acceptance:** hover delays, click-to-pin, Esc, external disk plug/unplug,
  light/dark, VoiceOver, multiple displays.
- **Performance:** idle < 1% CPU, < 60 MB RAM, measured with Instruments.

## 8. Project layout

```
project.yml          XcodeGen spec; SystemMetrics.xcodeproj is generated, not committed
Sources/
  App/            AppDelegate, StatusItemController, PanelController
  Metrics/        samplers, MetricsEngine, History, models
  Docker/         UnixSocketHTTPClient, DockerClient, models
  UI/             PanelView, cards, MenuBarLabel, SettingsView, theme
Tests/
  MetricsTests/   pure calculation + parsing tests
```

## 9. Workflow

Each change is test-driven, independently verified against the acceptance criteria above,
reviewed for security and design, and documented before it is pushed.

## 10. Risks

- `IOAccelerator` PerformanceStatistics keys are undocumented and may change between macOS
  versions → GPU card degrades to "veri yok", never crashes.
- Hover-to-open can trigger accidentally → 300 ms open delay (NN/g guidance for
  hover-revealed content), 500 ms close grace. *[rev R1]*
- Signing/notarization requires an Apple Developer account → unsigned dev builds until then.

## 11. Revisions

2026-10-16 — synced with the code at commit 66ce8c6. Inline marks *[rev Rn]* point here.

| # | Section | Was | Now (as implemented) |
|---|---|---|---|
| R1 | §1, §4, §10 | Open after 150 ms, close after 300 ms | Open after 300 ms, close after 500 ms (`HoverStateMachine.openDelay` / `closeDelay`) |
| R2 | §4 | Only click / Esc closed a pinned panel | Mouse-down outside the panel closes it in hover and pinned mode; also Space change, and app deactivation while pinned |
| R3 | §4 | Quit not specified (was a header button) | Quit lives in the status item's right-click / Control-click menu and in Settings; no quit button in the panel |
| R4 | §4 | Swap: used/total, bar | Used bytes, allocated size, compressed memory; no percentage, no bar |
| R5 | §4 | RAM coloured like other loads (used %) | RAM coloured by memory pressure |
| R6 | §4 | Docker CPU as a percentage | Docker totals in vCPUs of the Docker VM; RAM = usage − `inactive_file`; disk includes container writable layers |
| R7 | §4 | All mounted volumes | Network volumes skipped; local `/` and `/Volumes/*` only |
| R8 | §3, §4 | Socket order: `DOCKER_HOST`, `~/.docker/run/docker.sock`, `/var/run/docker.sock`; HTTP/1.1 | `DOCKER_HOST` (unix), Docker CLI context, then Docker Desktop, OrbStack, Colima (2 layouts), Rancher Desktop, `/var/run/docker.sock`; HTTP/1.0 GET only; `/_ping` added; max 30 containers per sample |
| R9 | §2 | Signed + notarized DMG | Still the target; until it exists, build from source only |
