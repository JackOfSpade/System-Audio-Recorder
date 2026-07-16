# System Audio Recorder — Design Document
### A native macOS system-audio recorder built on the Core Audio Process Tap (near-bit-perfect capture)

**Document status:** Complete architecture/design specification. No implementation code is included; this document is the sole context an implementer needs. "System Audio Recorder" is a working title and is trivially renameable (bundle identifiers `com.systemaudiorecorder.app` / `com.systemaudiorecorder.cli` are placeholders to be replaced with the owner's organization identifier).

---

## 1. Executive Summary

System Audio Recorder is a fully-owned, deeply customizable native macOS application that records what the Mac plays — the entire system mix, minus any apps you choose to exclude — at the highest fidelity macOS makes available to any third-party application. It is a menu-bar-first GUI app with a full sessions Library and Settings, paired with a standalone `systemaudiorecorder` command-line tool for headless and scripted use. Minimum deployment target is macOS 14.4; distribution is Developer ID–signed, notarized, hardened-runtime, **unsandboxed**, outside the Mac App Store.

**Core architecture.** Capture uses Apple's Core Audio **Process Tap** API: a `CATapDescription` (global, with exclusions) is instantiated with `AudioHardwareCreateProcessTap`, wrapped as a sub-tap inside a **private aggregate device** whose main sub-device is the real output device, and read with a **raw IOProc** registered via `AudioDeviceCreateIOProcIDWithBlock`. This delivers Core Audio's internal 32-bit float mix without installing a driver, without touching the user's audio routing, and without the Screen Recording–shaped compromises of ScreenCaptureKit. AVAudioEngine is explicitly banned from the capture path: it cannot be retargeted to a tap-backed aggregate device (the retarget silently no-ops and reads the default input instead) — a documented trap this design avoids by construction. Virtual-driver approaches (HAL plugin / AudioDriverKit) were evaluated and rejected: they add install friction, reroute the user's audio, introduce drift correction, and deliver **no fidelity advantage** over the tap.

**The fidelity target — stated honestly.** macOS applies a non-optional ingestion-side reconstruction filter to all Process Tap captures; on synthetic broadband signals (a 200 Hz square wave) this leaves a measurable Gibbs-ringing residual (≈ −2.9 dBFS RMS in null tests), so capture is *not* mathematically sample-identical. For real content it is perceptually and practically lossless, and — critically — this ceiling is imposed by the OS on every driverless third-party capture tool, including the leading commercial ones. System Audio Recorder's design goal is therefore **near-bit-perfect**: add *zero* degradation of its own. Concretely: capture at the output device's actual current nominal sample rate (never assumed, never converted), keep samples in 32-bit float end-to-end, apply no gain, dither, or resampling in the master path, and write masters as Float32 **CAF** — never WAV, which has a known Core Audio bug that silently truncates float to Int32. The validation plan (Section 10) includes a full null-test methodology to prove, and continuously re-prove, that System Audio Recorder sits exactly at the OS ceiling.

**Defensive engineering.** Two known macOS bugs shape the design. First, an intermittent failure mode in which the tap keeps delivering validly-timestamped buffers of exact zeros while audio audibly plays: System Audio Recorder runs a **ZeroWatchdog** that distinguishes this from genuine silence by corroborating sustained exact-zero runs against an independent "is any process actually emitting audio?" signal (`kAudioProcessPropertyIsRunningOutput`), and recovers with the only known-reliable fix — a full, strictly-ordered teardown and rebuild of the IOProc, aggregate device, and tap — while keeping the recording file open so sessions survive recovery (Section 8). Second, a level-attenuation bug on multi-output-channel devices (level scales roughly as 20·log₁₀ of the output stereo-pair count — ~12 dB measured on a 4-pair interface): System Audio Recorder detects at-risk devices, offers a one-shot calibration that measures the actual offset, stores it as metadata, and applies compensation on export — never silently altering the master (Section 8).

**Product shape and customizability.** The feature set is deliberately coherent rather than maximal: global system-mix recording with an app exclusion list; automatic session segmentation across device switches and sample-rate changes with a machine-readable `session.json` manifest; a lossless-first export pipeline (FLAC, ALAC, AAC, and compatibility WAV derived from the CAF master); live metering with capture-health status; and a full automation surface — CLI, URL scheme, Shortcuts (App Intents), shell hooks on session events, scheduled recordings, and "record while app X is playing" triggers. Excluded from v1, on purpose: live monitoring/routing (system audio is already audible), any sample-rate conversion anywhere, loudness normalization, and Mac App Store distribution (the tap API is unreliable under App Sandbox).

**Implementation stack.** Swift throughout, with one small C target (`SystemAudioRecorderRT`) for the real-time path: the IOProc callback only calls C ring-buffer functions, so the Swift runtime (ARC, exclusivity checks, allocation) can never stall the HAL real-time thread. A shared framework (`TapKit`) contains all capture, device, watchdog, file, and export logic and is consumed by both the GUI app and the CLI. The build proceeds in ten validated phases (Section 12), starting with a end-to-end spike (global tap → CAF file) that proves permissions, tap plumbing, and file integrity before any product code is written.

---

## 2. Tech Stack & Language Choice

### 2.1 Languages: Swift 5.10+, plus one small C target

Everything in System Audio Recorder is **Swift 5.10 or later**, with a single deliberate exception: the real-time capture path is a **C11 static library, `SystemAudioRecorderRT`** (see Section 4 for the target layout and Section 5 for the data flow through it).

The reason for the C island is the HAL real-time thread. The IOProc callback registered with `AudioDeviceCreateIOProcIDWithBlock` (with a `NULL` dispatch queue) runs directly on Core Audio's real-time I/O thread. Code on that thread must never block, never allocate, and never take a lock — a missed deadline means dropped capture buffers, an unrecoverable gap in the recording (and an I/O overload the HAL reports against our process). Swift cannot guarantee any of that:

- **ARC**: any retain/release traffic can allocate or contend on side-table locks; the compiler inserts retains/releases in places the author cannot fully control or audit.
- **Exclusivity enforcement**: Swift's runtime exclusivity checks can trap or take slow paths at unpredictable points.
- **Hidden allocation**: string interpolation, collection copy-on-write, existential boxing, and closure context capture can all heap-allocate invisibly.

C11 has none of these hazards and gives us exactly the two primitives the real-time path needs: `memcpy` into preallocated memory, and C11 atomics with explicit acquire/release ordering for the single-producer/single-consumer ring buffer (`td_ring_t`, fully specified in Section 5). The IOProc block itself is trivially small: it captures **only an unmanaged raw pointer** to a preallocated C context struct and calls `SystemAudioRecorderRT` C functions — no Swift objects, no ObjC messaging, no logging, no syscalls. Everything else in the product (device management, watchdogs, file writing, export, UI) has no real-time constraint and stays in Swift where it is faster to write correctly.

### 2.2 Frameworks (exact list — nothing else)

| Framework | Used for |
|---|---|
| **CoreAudio** (C API) | The entire capture mechanism: `AudioHardwareCreateProcessTap`, `CATapDescription`, `AudioHardwareCreateAggregateDevice`, `AudioDeviceCreateIOProcIDWithBlock`, `AudioObjectGetPropertyData`/listeners (`AudioHardware*`, `AudioDevice*`, `AudioObject*`). |
| **AudioToolbox** | `ExtAudioFile` for writing/reading the CAF Float32 masters (Section 6); `AudioConverter`/`ExtAudioFile` for export transcodes (FLAC/ALAC/AAC/WAV24, Section 6). |
| **Accelerate (vDSP)** | Drain-thread metering (per-channel peak + RMS) and the all-zero scan (max-magnitude == 0.0) used by `ZeroWatchdog` (Sections 5 and 8). |
| **SwiftUI + AppKit** | All GUI (Section 3). AppKit owns the lifecycle; SwiftUI renders the views (see 2.5). |
| **UserNotifications** | Alerts: trigger start/stop, dropout escalation, device-wait timeout, disk-space stop (Section 3). |
| **AppIntents** | Shortcuts actions: Start/Stop Recording, Get Recording Status (Section 3). |
| **os (os.Logger)** | Structured logging everywhere **except** the real-time thread, which never logs. |
| **Carbon (HIToolbox)** | `RegisterEventHotKey` only, used solely by `HotkeyCenter` in the GUI target for global hotkeys (Section 3.13). Never linked into `TapKit` or anywhere near the capture path. It is legacy but supported, permission-free, and the only dependency-free way to get consuming global hotkeys. |
| **Foundation / Dispatch** | The engine queue (Section 4.4), `Thread` for `DrainLoop`, JSON manifests, file management. |
| **AVFoundation** | **Playback side only, never capture**: `CalibrationService` test-tone playback (Section 8) and the null-test harness (Section 10) may play audio with `AVAudioPlayer`. The capture side never touches AVFoundation. |

### 2.3 Why AVAudioEngine is banned from the capture path

This is a hard constraint, not a preference. The documented trap, stated precisely:

> **AVAudioEngine cannot be retargeted to a tap-backed aggregate device.** Setting `kAudioOutputUnitProperty_CurrentDevice` on the engine's underlying input unit to the private aggregate's `AudioObjectID` **returns `noErr`** — no error, no exception — but the engine **silently keeps reading from the system default input device** (typically the microphone) instead of the aggregate.

The failure mode is the worst kind: a plausible-looking, correctly-timestamped audio stream that is simply the *wrong audio*. Nothing throws; only listening to the recording reveals the bug. Therefore the capture path reads tap audio exclusively via a **raw IOProc** registered with `AudioDeviceCreateIOProcIDWithBlock` on the private aggregate device (recipe in Section 4.5, data flow in Section 5).

Also explicitly forbidden anywhere in the master path (rationale in Sections 5 and 6): `AVAudioFile`-to-WAV for masters (the documented Core Audio bug that silently truncates Float32 samples to Int32 in WAV containers), any sample-rate conversion, and any dither. Dither exists only in `ExportService` for 16-bit derivative exports (Section 6).

### 2.4 Why no third-party dependencies

Core System Audio Recorder has **zero third-party dependencies**. Reasons, in order of weight:

1. **The Core Audio C API *is* the product surface.** The design depends on exact property constants, exact call ordering, and exact teardown sequences (Sections 4 and 8). Wrapper libraries hide precisely the details that Bug A and Bug B force us to control.
2. **Real-time auditability.** Every instruction that can run on the HAL thread must be inspectable; a dependency in that path would be unauditable risk.
3. **Distribution simplicity.** Developer ID signing, hardened runtime, and notarization (Section 9) are simplest with a dependency-free build; there is no supply chain to re-verify at each release.
4. **Full-ownership goal.** The reason this app exists (versus buying Audio Hijack) is total control of the source.

The single sanctioned exception: **Sparkle 2** for auto-updates, optional, GUI-only, and only in Phase 9 (Section 12). The CLI never links it.

### 2.5 Why AppKit lifecycle with SwiftUI views

System Audio Recorder is a **menu-bar-first** app (`NSStatusItem`, `LSUIElement = YES`). That shape needs AppKit-level control that the pure SwiftUI `App`/`MenuBarExtra` lifecycle does not reliably provide on macOS 14.4:

- Precise `NSStatusItem` control (custom click handling, programmatic popover/menu behavior, status-icon state changes for the health chip).
- Deterministic management of exactly two windows (Library, Settings) — creation, restoration, and ordering from a status-item app.
- A natural home for `HotkeyCenter`'s global hotkey registration and for app-lifecycle glue (launch crash-recovery scan, termination finalization).

So: an **AppDelegate owns the status item and the two windows; each window hosts a SwiftUI root view** via `NSHostingController`. SwiftUI is used for all view content (meters, session lists, settings forms) because it is dramatically faster to build and iterate, and none of it is anywhere near the real-time path. This split is one-way: SwiftUI views call into `TapKit` (Section 4); `TapKit` never imports SwiftUI or AppKit.

### 2.6 Project layout

A **single Xcode project** with the four targets of Section 4.1 (`SystemAudioRecorderRT` C static library, `TapKit` Swift framework built for static linkage, `SystemAudioRecorderApp` app, `systemaudiorecorder` command-line tool). No SwiftPM manifest is required in v1; nothing about the design precludes migrating `SystemAudioRecorderRT`/`TapKit` to local Swift packages later.

---

## 3. Feature Set & UX/CLI Design

### 3.1 Product shape

System Audio Recorder ships as two executables built on one shared framework (`TapKit`, see Section 4):

1. **Menu-bar-first GUI app** (`com.systemaudiorecorder.app`). An `NSStatusItem` app with `LSUIElement = YES`. It has exactly two windows — **Library** (session browser + export) and **Settings** — both SwiftUI views hosted in an AppKit lifecycle: the AppDelegate owns the status item and the windows, each window hosting a SwiftUI root view.
2. **Standalone CLI `systemaudiorecorder`** (`com.systemaudiorecorder.cli`, embedded Info.plist via the `__info_plist` linker section). Fully headless; it instantiates the same `CaptureEngine` the GUI uses.

The two binaries do **not** talk to each other — no XPC or IPC in v1. Consequence the implementer must surface in docs and onboarding: macOS grants system-audio-capture permission per bundle id, so a user who uses both the app and the CLI will see **two separate TCC prompts** (one per binary). This is an accepted v1 trade-off for simplicity (see Section 9 for the permission flow).

### 3.2 Feature set — what is IN v1

One honesty note frames everything in this table: System Audio Recorder targets "near-bit-perfect", not bit-perfect — macOS applies a non-optional reconstruction filter to all Process Tap captures, measurable on synthetic signals but perceptually lossless on real content, and every driverless third-party recorder (including commercial tools) sits at this same OS-imposed ceiling. System Audio Recorder's job is to add zero degradation of its own (Section 1, Section 10).

| Feature | Summary | Why it's in |
|---|---|---|
| System-mix recording | Global tap of everything the Mac plays, minus an exclusion list | The core promise |
| Device targeting | Follow system default (with mid-session device switching) or pin a fixed device | Fidelity depends on which device's rate/format we tap (Section 7) |
| Float32 CAF masters | Untouched, tap-native rate, crash-safe segments | Fidelity rule (Section 6) |
| Exports | FLAC 16/24, ALAC 16/24, AAC ~256 kbps VBR, WAV 24-bit (compatibility only) — always from the master | Small shareable files without compromising the archive |
| Calibration + level compensation | Bug-A measurement, metadata-only by default | Correct levels without touching master samples (Section 8) |
| Self-healing capture | ZeroWatchdog rebuilds on the all-zero dropout bug | Reliability for long unattended recordings (Section 8) |
| Automation | CLI, URL scheme, App Intents, shell hooks, schedule + app-activity triggers, global hotkeys | "Fully owned and customizable" is the reason this app exists |
| Library | Browse, inspect events/health, export, reveal in Finder | Recordings are useless if you can't find them |
| Silent capture | Advanced toggle: mute system output while the tap keeps recording | Record overnight without hearing playback |

### 3.3 Deliberately OUT of v1 — and why

Each exclusion is a decision, not an omission. The implementer must not add these "while in there."

- **No live monitoring / passthrough.** The tap's default `muteBehavior` is `.unmuted`, so the user already hears the audio through the normal output path; a monitor path would add a second output route, latency management, and a strong temptation to reach for AVAudioEngine — which is banned from the capture path (Section 2).
- **No loudness normalization, EQ, effects, or any DSP.** The master is raw by definition. Gain compensation exists only as export-time scalar multiply plus metadata (Section 8); everything else is out.
- **No sample-rate conversion in any System Audio Recorder code path.** Capture is at the tapped device's native nominal rate and exports keep the master's rate. SRC would silently break the "near-bit-perfect" claim. The one deliberate exception is the default-off advanced **Forced-rate mode** (3.6.3, Section 7), which does not resample in System Audio Recorder either — it delegates resampling to macOS and therefore carries a verbatim fidelity warning.
- **No pre-roll on triggers.** App-activity triggers can miss up to ~1 s of lead-in (see 3.12). Pre-roll would require a permanently running tap (constant CPU, a permanently "in use" capture grant, and privacy optics). Documented limitation instead.
- **No audio editing** (trim/split/join) in Library. Export-only in v1.
- **No microphone/input capture.** System Audio Recorder records what the Mac *plays*, only.
- **No streaming/broadcast output, no cloud sync.**
- **No Mac App Store build** — the Process Tap API is unreliable under App Sandbox (Section 9).
- **No GUI↔CLI IPC** (see 3.1).

### 3.4 Source model

A recording is fully described by a `SessionSpec` (consumed by `CaptureEngine`, Section 4). Recording is always a single global tap built with `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, configured by:

- **`excludeBundleIDs: [String]`** — bundle ids excluded from the tap. The exclusion list ALWAYS contains System Audio Recorder's own PID (prevents feedback if System Audio Recorder ever emits UI sounds); the user can add more apps to exclude (e.g. record everything except a video call). UI label: **"System Audio"**, with an "Exclude apps…" disclosure.

There is no per-app or multi-track capture mode — an earlier revision of this design supported selecting specific apps to isolate (`.appSet`, with an optional one-lane-per-app `multiTrack` mode and an unmixed `matchDeviceLayout` tap variant). It was removed: a global tap already captures whatever is playing, muting the physical output doesn't affect what the tap sees (Section 1), and maintaining per-app isolation as a second capture path wasn't worth the surface area for a single-source-at-a-time usage pattern. `muteBehavior` is `.unmuted` by default; `.mutedWhenTapped` is exposed as the **"Silent capture"** advanced toggle in Settings → Recording.

### 3.5 Device targeting

`SessionSpec.device` is either:

- **`.followSystemDefault`** (default) — tap whatever the default output device is; if the user switches (AirPods connect, etc.), the lane rebuilds against the new device and rotates to a new segment (Section 7).
- **`.fixed(deviceUID: String)`** — pin a specific device; if it disappears the lane enters `WAITING_FOR_DEVICE` for up to 5 minutes before finalizing gracefully (Section 7).

The UI shows the resolved device plus its current nominal sample rate at all times, and a Bug-A warning badge whenever the device exposes more than 2 output channels (Section 8).

### 3.6 UI walkthrough

#### 3.6.1 Menu-bar dropdown

Status-item icon: a template waveform glyph; while recording it gains a red recording dot; while `REBUILDING`/`WAITING_FOR_DEVICE` the dot pulses amber; in the Error/`FAILED` state the glyph gains a small ✕ badge that persists until the user opens the dropdown and acknowledges the error line. The dropdown, top to bottom:

1. **Record/Stop button** — large, single primary action for the currently configured `SessionSpec`.
2. **Source readout** — always "System Audio", with an "Exclude apps…" disclosure that opens a picker listing running audio-capable processes from `ProcessCatalog`, each with a live-output dot (`kAudioProcessPropertyIsRunningOutput`) so the user can see who is actually playing, and lets them add/remove bundle ids from the tap's exclusion list.
3. **Device readout** — resolved output device name + current sample rate (e.g. "MacBook Pro Speakers — 48.0 kHz"), with the Bug-A badge when applicable.
4. **Live meters** — per-channel peak + RMS bars, refreshed at 20 Hz from the drain thread's atomic meter snapshot (Section 5); shows the "cal" badge when displaying calibration-compensated values; hosts the clip indicator (3.7).
5. **Elapsed time** and current session size on disk.
6. **Health chip** — one of: ● Recording / ⚠ Rebuilding / ◌ Waiting for device / ✕ Error. Clicking it reveals the last event line (e.g. "Recovered from dropout, 240 ms gap").
7. **Open Library** and **Settings…** items; **Quit System Audio Recorder** (disabled with an explanatory tooltip while recording; the user must stop first — prevents accidental data loss).

#### 3.6.2 Library window

- **Sessions list** (left): date, source, duration, size, and health badges — *Recovered* (crash-recovered session), *Had dropouts* (any `zeroDropoutRebuild` event), *Had gaps* (any `overrunGap` event).
- **Session detail** (right): lanes and their segments (file, rate, channels, frames), an **events timeline** rendering every manifest event (`deviceSwitch`, `rateChange`, `zeroDropoutRebuild`, `overrunGap`, `waitingForDevice`, `error`) at its wall-clock position, and the device/rate history.
- **Export panel**: format preset (FLAC 16/24, ALAC 16/24, AAC, WAV 24 — WAV labeled "compatibility only"), dither toggle (default ON for 16-bit), "Apply level compensation" toggle (default ON when a calibration profile exists), destination. Copy must include the honesty line from Section 6: the CAF float master is the only true archive; 16/24-bit exports are bit-depth reductions.
- **Reveal in Finder** per session and per file.

#### 3.6.3 Settings window — five tabs

| Tab | Contents |
|---|---|
| **General** | Recordings folder (default `~/Music/System Audio Recorder/`), session naming template with token reference (`{date} {time} {source} {app} {device} {rate}`), hotkey editor |
| **Recording** | Exclusion-list editor, device policy (follow default / fixed + picker), timeline policy (`preserveWallClock` default / `compressTimeline`), Silent-capture toggle, optional segment duration/size caps (default OFF) |
| **Formats & Export** | Default export presets, dither policy, compensation policy ("Bake compensation into master" lives here, default OFF, with its sample-modification warning) |
| **Automation** | Shell hooks (3.11), triggers and schedules (3.12) |
| **Advanced** | Buffer frame size — read-only, set automatically by the "Run Calibration…" button (`CalibrationService.recommendBufferFrameSize`, distinct from the Bug-A gain calibration below; probes down to this Mac's actual `kAudioDevicePropertyBufferFrameSizeRange` floor; 512 fallback if never calibrated) rather than hand-tuned, persisted to the shared per-device buffer-calibration store (Section 4.5 step 5) so the CLI's `record` honors the same result, watchdog thresholds group (Section 8 defaults), Forced-rate mode with the verbatim warning from Section 7 ("Forcing a rate different from the output device's current rate makes macOS resample the audio before System Audio Recorder can capture it. Only use this if you need a fixed rate more than you need maximum fidelity."), Calibration manager (per-device profiles, re-run, delete), Diagnostics/log export |

#### 3.6.4 Onboarding

First launch shows a single sheet (full flow specced in Section 9): what System Audio Recorder records and why macOS will ask → **"Enable System Audio Capture"** button → `PermissionBroker` runs the throwaway-tap probe → system prompt appears → success proceeds to a 10-second guided test recording ("play some audio, press Record" — an onboarding nicety layered on top of the Section 9 permission flow, not part of it; it runs only after that flow completes); denial swaps the button for **"Open System Settings"** deep-linking to Privacy & Security → Screen & System Audio Recording. Onboarding also states plainly that the `systemaudiorecorder` CLI will request its own separate permission the first time it records.

### 3.7 Notifications, disk guard, clip indicator

- **Notifications** (UserNotifications framework): recording started/stopped by a trigger; watchdog escalation ("Capture appears broken; System Audio Recorder keeps retrying"); device-wait timeout ("Recording stopped: <device> did not return within <timeout>."); disk-space stop. No notification for manual start/stop — the user just did it.
- **Disk guard**: while any lane is recording, check free space on the recordings volume every 10 s; below **500 MB**, stop gracefully (full `FINALIZING`, manifest intact) and notify. The menu-bar dropdown shows a passive free-space readout below 5 GB.
- **Clip indicator**: the meter block flags any sample with magnitude ≥ 1.0 and holds the indicator for 2 s. UI copy notes that float samples above 1.0 are legal and the float master preserves them unclipped — the indicator warns about *downstream* integer exports, and is one more reason the master is float.

### 3.8 CLI verb reference

Shared exit codes: **0** ok · **2** permission denied · **3** device/app not found · **4** capture error · **5** disk error · **64** usage error. Ctrl-C during `record` performs a graceful stop/finalize and exits 0.

| Verb | Behavior |
|---|---|
| `systemaudiorecorder record [--device <uid\|name>] [--out <dir>] [--duration <sec>] [--max-silence-stop <sec>]` | Records the global system mix until Ctrl-C, `--duration` elapses, or silence-stop fires. `--max-silence-stop N` stops after N continuous seconds of digital silence — counted only while the ZeroWatchdog does NOT classify the zeros as a dropout (a confirmed dropout triggers rebuild, not stop). I/O buffer size is resolved from the shared buffer-size calibration store for the resolved device if one exists (Section 4.5 step 5), 512 frames otherwise — the CLI has no `calibrate`-buffer flag of its own, but honors a calibration run from the GUI. Prints the session path on exit. |
| `systemaudiorecorder devices [--json]` | Output devices with UID, channel count, current nominal rate, and a Bug-A risk flag for > 2 output channels. |
| `systemaudiorecorder apps [--json]` | Running audio-capable processes: bundle id, PID, name, is-outputting-now. |
| `systemaudiorecorder sessions [--json]` | **Removed** with the session-folder/library simplification — recordings are now flat files in the recordings folder; there is no library index to list. |
| `systemaudiorecorder export <session-path> --format flac16\|flac24\|alac16\|alac24\|aac\|wav24 [--compensate-gain on\|off] [--out <dir>]` | **Removed** with the export simplification — `record --format wav32\|caf32` chooses the output format directly at stop time, and Bug-A gain compensation is applied automatically to WAV output when a calibration profile exists. |
| `systemaudiorecorder calibrate [--device <uid\|name>]` | Runs the Bug-A calibration pass (Section 8) after an explicit y/N confirmation that a 5 s test tone will play. The target must currently be the system default output device (tone playback has no per-device routing). |

Human-readable output goes to stdout, diagnostics to stderr; `--json` variants emit stable machine-readable schemas for scripting.

`--device` resolution rule: the argument is first matched as a device UID; failing that, as a case-insensitive device name. Device names are not unique — if a name matches more than one device, the command exits **3** and lists the matching UIDs on stderr so the user can retry with a UID.

Runtime events during `systemaudiorecorder record` mirror the GUI: every event that would post a notification or change the health chip — dropout progression (SUSPICIOUS → confirmed → rebuild → ESCALATED), the persistent-overrun warning, device wait and device return, and the disk-space stop — is emitted as a timestamped line on stderr. A disk-space stop performs a graceful finalize and then exits **5**; a device-wait timeout performs a graceful finalize and exits **0** (a valid session was produced); ESCALATED keeps recording and keeps emitting stderr warnings.

### 3.9 URL scheme

The GUI app registers `systemaudiorecorder://` (CFBundleURLTypes):

- `systemaudiorecorder://record/start` — start a system-mix recording with current settings.
- `systemaudiorecorder://record/stop` — graceful stop.

If a recording is already running, `start` is ignored and a notification explains why. URLs drive the GUI app's engine only (no IPC to CLI sessions).

### 3.10 App Intents (Shortcuts)

Three intents, exposed via the AppIntents framework from the GUI app:

- **Start Recording** — parameters: optional device.
- **Stop Recording** — no parameters; returns the finalized session path.
- **Get Recording Status** — returns: recording yes/no, elapsed seconds, source description, health state string.

### 3.11 Shell hooks

Settings → Automation exposes three optional hook commands, each run non-blocking with a 30 s timeout, stdout/stderr captured to the app log:

- `onSessionStart` — after the first lane reaches `RUNNING`.
- `onSegmentClose` — after each segment finalizes (rotation or stop).
- `onSessionFinalize` — after the manifest gains `finalizedAt`.

Environment variables provided: `SYSTEMAUDIORECORDER_SESSION_PATH` (always), `SYSTEMAUDIORECORDER_SEGMENT_PATH` (segment-scoped hooks), `SYSTEMAUDIORECORDER_EVENT` (hook name). Hooks never block or fail the capture pipeline; a timed-out hook is killed and logged.

### 3.12 Triggers

Both trigger types live in Settings → Automation and are executed by `TriggerEngine`:

- **Schedule rules**: start at time T for duration D, with optional weekday repeat. If a rule fires while a recording is already running, the rule is skipped and a notification says so (no queuing in v1).
- **App-activity auto-record**: armed per app. While any trigger is armed, `ProcessCatalog` polls `kAudioProcessPropertyIsRunningOutput` at 1 Hz; recording starts on the first `true` poll and stops after `hangTime` (default 10 s, configurable) of continuous no-output. A fired app trigger starts a normal global system-mix session using the current device policy and recording settings — the armed app is only what starts/stops the recording, not what's isolated within it (there is no per-app isolation, Section 3.4). If any recording is already running when an app trigger fires (manual, scheduled, or another armed app), the trigger is skipped with a notification — same policy as schedule rules — and may fire again once the engine is idle and the app is still outputting. **Documented limitation, shown in the arming UI**: because detection is a 1 Hz poll and there is no pre-roll in v1, up to ~1 s of audio lead-in may be missed at the start.

Trigger-started and trigger-stopped sessions always post notifications (3.7).

### 3.13 Hotkeys

`HotkeyCenter` registers global hotkeys via Carbon's `RegisterEventHotKey` (works while the app is background-only; no Accessibility permission needed). Default: **⌃⌥⌘R = toggle record** with the current default `SessionSpec`. The General tab's hotkey editor lets the user rebind it and optionally assign two additional actions that ship unassigned: "Stop recording" and "Open Library". Conflict handling, stated precisely: a registration failure (e.g. `eventHotKeyExists`) detects collisions with hotkeys registered by *other apps* and is surfaced inline in the editor; collisions with macOS *system* shortcuts (Keyboard settings, Spotlight, screenshots…) generally do **not** fail registration and cannot be reliably detected — the editor shows a generic caution that system shortcuts may shadow the chosen combo.

---

## 4. System Architecture

### 4.1 Build targets (four)

| Target | Kind | Bundle / linkage | Contents |
|---|---|---|---|
| **`SystemAudioRecorderRT`** | C11 static library | linked into `TapKit` | The lock-free SPSC ring buffer `td_ring_t`, the preallocated real-time capture context struct, and the only functions the IOProc ever calls: ring write, atomic host-time/frame-count stores, atomic dropped-chunk/dropped-frame counters. Depends on libc only. Full spec in Section 5. |
| **`TapKit`** | Swift framework | statically linked into both executables | ALL capture, device, file, watchdog, export, and trigger logic. No UI imports whatsoever. Contains every module in 4.2. |
| **`SystemAudioRecorderApp`** | GUI app | `com.systemaudiorecorder.app` | AppKit lifecycle + SwiftUI views (Section 2.5), onboarding, Library and Settings windows, menu-bar UI (Section 3). |
| **`systemaudiorecorder`** | CLI executable | `com.systemaudiorecorder.cli`, Info.plist embedded via the `__info_plist` linker section | Fully headless. Verbs and exit codes in Section 3. Has its **own** TCC grant (own bundle id, own `NSAudioCaptureUsageDescription`) — see Section 9. |

Dependency graph (arrows = "links against"):

```
SystemAudioRecorderApp ---+
                           +---> TapKit ---> SystemAudioRecorderRT
    systemaudiorecorder ---+
```

`TapKit` is built for **static linkage** so the CLI ships as a single self-contained binary with no `@rpath` framework lookup. GUI and CLI each instantiate their **own `CaptureEngine`** in their own process; there is **no XPC/IPC in v1**. Consequence (accepted trade-off, stated once here and in Section 9): the user may see **two** system-audio permission prompts over the product's life — one for the app, one for the CLI.

### 4.2 TapKit module map

These names are canonical; use them exactly as type names.

- **`CaptureEngine`** — top-level orchestrator. Accepts a `SessionSpec` — exclusion list + device policy + tap config, normatively defined in Sections 3.4–3.5 — asks `SessionStore` to create the session folder + manifest, creates and owns the single `CaptureLane` instance (4.6), and runs the session lifecycle (start, stop, finalize). Owns the **engine queue** (4.4) on which every Core Audio hardware call in the process is serialized. Exposes async start/stop with completion callbacks and a polled status snapshot; callers (GUI/CLI) never block on it.

- **`CaptureLane`** — the single capture pipeline: tap + private aggregate device + IOProc + `td_ring_t` ring + drain thread + segment writer + watchdog (4.6). Runs the **lane state machine** (`IDLE → PREPARING → RUNNING ⇄ REBUILDING`, etc.) fully specified in Section 8. Owns its instances of `TapFactory` products, `IOProcHost`, `DrainLoop`, `SegmentWriter`, and `ZeroWatchdog`.

- **`TapFactory`** — creates and destroys the `CATapDescription`, the process tap, and the private aggregate device. It owns the exact creation recipe (4.5) and executes the strict teardown order (canonical spec in Section 8). No other module ever calls `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`, or their destroy counterparts.

- **`IOProcHost`** — registers the IOProc via `AudioDeviceCreateIOProcIDWithBlock`, passing a **`NULL` dispatch queue** so the callback fires on the HAL real-time thread. The block captures exactly one thing: an unmanaged pointer to the lane's preallocated C context struct, and only calls `SystemAudioRecorderRT` C functions. `IOProcHost` also issues `AudioDeviceStart`/`AudioDeviceStop` (on the engine queue).

- **`DrainLoop`** — one dedicated `Thread` per lane (QoS `.userInitiated`), polling on a **50 ms** cycle. Per cycle: read all available whole frames from the ring (chunks ≤ 1 s), run zero-detection (vDSP max-magnitude), compute per-channel peak+RMS meters (vDSP), interleave if the tap delivered non-interleaved buffers (bit-exact reordering only), write to disk **synchronously** via `SegmentWriter`, do `ZeroWatchdog` bookkeeping, and publish a meter snapshot to an atomic slot the UI polls at 20 Hz. Full data-flow spec in Section 5.

- **`SegmentWriter`** — writes CAF Float32 segments via `ExtAudioFile` with **identical client and file ASBDs** so no converter is ever engaged (Section 6). Handles segment rotation (device switch, rate change, optional caps) and finalization; crash-safe via CAF's unknown-size (`-1`) audio data chunk.

- **`ZeroWatchdog`** — the Bug-B all-zero dropout detector and rebuild executor. State machine, thresholds (5 s / 10 s / 60 s, backoff 0.5 s / 2 s / 5 s, 3 attempts per 10-minute window), and corroboration logic are canonical in Section 8. Detection and all state transitions run on the drain thread; the rebuild itself is enqueued onto the engine queue and performed by `TapFactory`/`IOProcHost` as a full teardown + recreate.

- **`DeviceObserver`** — registers CoreAudio property listeners for: default output device changed (`kAudioHardwarePropertyDefaultOutputDevice`), device nominal sample rate changed (`kAudioDevicePropertyNominalSampleRate`), and device list changed / device died. Listener blocks are registered **with the engine queue as their dispatch queue**, so all reactions (Section 7) are already serialized.

- **`ProcessCatalog`** — enumerates audio-capable processes via `kAudioHardwarePropertyProcessObjectList`; translates PID → process `AudioObjectID` via `kAudioHardwarePropertyTranslatePIDToProcessObject`; reads per-process `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyPID`, and `kAudioProcessPropertyIsRunningOutput`. Polls at **1 Hz only** while (a) a picker UI is visible, (b) triggers are armed, or (c) any lane's watchdog is in any non-`NORMAL` state (the full dropout episode — see Section 8.1). Polls execute on the engine queue.

- **`PermissionBroker`** — determines TCC status by attempting a minimal throwaway probe tap (public API only by default); optional `PRIVATE_TCC_PROBE` build flag (default OFF) for the private-SPI exact-status probe. Both paths are fully described in Section 9. Probe attempts run on the engine queue.

- **`CalibrationService`** — Bug-A calibration: with user consent, plays a 997 Hz test tone through the target device while capturing via a temporary lane, measures the RMS delta, and stores a per-device gain profile keyed by `(deviceUID, outputChannelCount, macOSBuild)`. Full spec in Section 8; playback may use AVFoundation (Section 2.2), capture uses a normal lane.

- **`SessionStore`** — creates session folders under the recordings root, reads/writes the `session.json` manifest, maintains the library index, and runs the crash-recovery scan at launch (Section 6).

- **`ExportService`** — post-capture transcodes from the CAF float master: FLAC (16/24-bit), ALAC (16/24-bit), AAC (~256 kbps VBR), WAV (24-bit int, compatibility only). Optional gain compensation; TPDF dither default-ON for 16-bit reductions. Full spec in Section 6.

- **`TriggerEngine`** — scheduled recordings, app-audio-activity auto-record (via `ProcessCatalog` polling), and user shell hooks (`onSessionStart`, `onSegmentClose`, `onSessionFinalize`). Surface in Section 3.

- **`HotkeyCenter`** — global hotkeys (default ⌃⌥⌘R record toggle; configurable). Registered by the GUI app only; the CLI does not use it.

### 4.3 Component diagram

```
   +--------------------------------+     +--------------------------------+
   |  SystemAudioRecorderApp (GUI)  |     |  systemaudiorecorder (CLI)     |
   |  com.systemaudiorecorder.app   |     |  com.systemaudiorecorder.cli   |
   |  AppKit lifecycle +            |     |  headless, own TCC grant       |
   |  SwiftUI views                 |     |                                |
   +---------------+----------------+     +----------------+---------------+
                   |    SessionSpec / start / stop / status snapshots
                   +---------------------------+------------+
                                               v
 ====================  TapKit (Swift framework, no UI)  ====================
                                               |
     +-----------------------------------------+------------------------+
     |                       CaptureEngine                              |
     |  owns the ENGINE QUEUE (one serial dispatch queue):              |
     |  EVERY AudioHardware*/AudioDevice*/AudioObject* call in the      |
     |  process runs on it -- sole exception: the IOProc callback       |
     +--------+-----------------------------------------------------+
              | owns the single capture lane
              v
     +---------------------- CaptureLane ----------------------------+
     |                                                              |
     |  TapFactory ------> process tap + private aggregate device   |
     |       |                                                      |
     |       v                                                      |
     |  IOProcHost ------> IOProc on HAL REAL-TIME thread           |
     |       |             (C context only -- no Swift runtime)     |
     |       v                                                      |
     |  SystemAudioRecorderRT ring (td_ring_t: lock-free SPSC ring) |
     |       |                                                      |
     |       v  50 ms poll, dedicated Thread per lane               |
     |  DrainLoop --+--> SegmentWriter --> <lane-slug>/segment-NNN.caf
     |              |                                               |
     |              +--> ZeroWatchdog --(rebuild request)-----------+---> engine queue
     +--------------------------------------------------------------+

     Supporting services (all Core Audio touches hop to the engine queue):
     +----------------+  +----------------+  +------------------+
     | DeviceObserver |  | ProcessCatalog |  | PermissionBroker |
     +----------------+  +----------------+  +------------------+
     +----------------+  +----------------+  +------------------+
     | SessionStore   |  | ExportService  |  | TriggerEngine    |
     +----------------+  +----------------+  +------------------+
     (plus CalibrationService and HotkeyCenter)
 =============================================================================
                                               |
                                               v  (linked C static library)
                               +--------------------------------+
                               |  SystemAudioRecorderRT (C11)   |
                               |  td_ring_t + context           |
                               +--------------------------------+
```

### 4.4 The engine-queue serialization rule

`CaptureEngine` owns **one dedicated serial dispatch queue** — the **engine queue** (label `com.systemaudiorecorder.engine`, QoS `.userInitiated`; one per `CaptureEngine` instance, i.e. one per process).

**The rule:** every call into the HAL object APIs — `AudioHardware*`, `AudioDevice*`, and `AudioObject*` functions operating on `AudioObjectID`s — anywhere in the process executes on the engine queue. The **only exception** is the IOProc callback itself, which is invoked *by* the HAL on its real-time thread and calls **no Core Audio API at all** (it only calls `SystemAudioRecorderRT` C functions).

Concretely, on the engine queue: all `TapFactory` create/destroy calls, all `IOProcHost` register/start/stop/destroy calls, all `ZeroWatchdog` rebuild executions, all `DeviceObserver` listener callbacks (registered with the engine queue as their dispatch queue), all `ProcessCatalog` property reads, all `PermissionBroker` probes, and all `CalibrationService` lane setup/teardown.

Scope note: the rule covers the HAL object graph, **not** the AudioToolbox file APIs. Each lane's `ExtAudioFileRef` is confined to that lane's drain thread, and `ExportService` uses its own `ExtAudioFile`/`AudioConverter` instances on a background queue — those never touch the engine queue.

Why the rule exists:
1. **Rebuild races.** A `ZeroWatchdog` rebuild and a `DeviceObserver` device-switch reaction can otherwise interleave teardown/creation on the same lane; serialized, one completes fully before the other observes the resulting state.
2. **Strict ordering guarantees.** The teardown order (Section 8) and creation order (4.5) are only meaningful if no concurrent HAL call can slip between steps.
3. **Deterministic listener context.** Property listeners arrive on a known queue with a known consistency snapshot of engine state.
4. **UI isolation.** UI and CLI threads never make blocking HAL calls; they enqueue work and read published snapshots (meters via the 20 Hz atomic slot, Section 5; lane states via `CaptureEngine` status).

### 4.5 Core Audio object creation recipe (canonical)

This is the per-lane creation sequence. All seven steps run on the engine queue, in this order, inside the lane's `PREPARING` state (on any OSStatus error: retry once after 250 ms, then transition to `FAILED` with the OSStatus surfaced — Section 8).

1. **Resolve the target device.** From the `SessionSpec` device policy (Section 7): obtain the output device's `AudioObjectID` and its device UID string; read `kAudioDevicePropertyNominalSampleRate` and the output channel count. The nominal rate is the expected capture rate (never assumed or hardcoded — Section 7); the channel count feeds the Bug-A heuristic (Section 8).
2. **Build the `CATapDescription`** using `CATapDescription(stereoGlobalTapButExcludeProcesses:)` — always a global stereo tap, always excluding System Audio Recorder's own PID plus the user's exclusion list (Section 3.4). Set: a human-readable name, mute behavior (`.unmuted` default, `.mutedWhenTapped` for silent capture), and **private = true**.
3. **Create the tap:** `AudioHardwareCreateProcessTap(description) → tapID`. Immediately read back `kAudioTapPropertyUID` (needed for step 4) and `kAudioTapPropertyFormat` (the ASBD that is ground truth for all IOProc data — Section 5; assert its rate matches step 1's nominal rate, and if not, log and trust the tap format — Section 7).
4. **Build the aggregate-device composition dictionary** with exactly these keys, then call `AudioHardwareCreateAggregateDevice(dictionary) → aggID`:
   - `kAudioAggregateDeviceNameKey` : `"System Audio Recorder Capture <lane-slug>"`
   - `kAudioAggregateDeviceUIDKey` : a fresh UUID string (unique per creation, including rebuilds)
   - `kAudioAggregateDeviceIsPrivateKey` : `true` (invisible to other apps and to the user's device list)
   - `kAudioAggregateDeviceIsStackedKey` : `false`
   - `kAudioAggregateDeviceTapAutoStartKey` : `true`
   - `kAudioAggregateDeviceSubDeviceListKey` : array of one dictionary: `{ kAudioSubDeviceUIDKey : <real output device UID from step 1> }`
   - `kAudioAggregateDeviceMainSubDeviceKey` : `<real output device UID from step 1>`
   - `kAudioAggregateDeviceTapListKey` : array of one dictionary: `{ kAudioSubTapUIDKey : <tap UID from step 3>, kAudioSubTapDriftCompensationKey : true }`
5. **Set the aggregate's IO buffer size:** `kAudioDevicePropertyBufferFrameSize` = `CalibrationService.effectiveBufferFrameSize(forResolvedDevice:)`'s result for the resolved device — the last size `recommendBufferFrameSize` (Section 3.6.3) found for that `deviceUID`, read from a shared JSON file at `~/Library/Application Support/System Audio Recorder/buffer-calibration.json` (same rationale and locking discipline as the Bug-A `calibration.json` profile store, Section 8.3: GUI and CLI are separate processes with separate `UserDefaults` domains, so only a shared file lets a calibration run in one be honored by the other); **512** frames if that device has never been calibrated. No manual override in Advanced settings. `CaptureLane` resolves the target device once per build/rebuild and reuses that single resolution for both the calibration lookup and this step (never twice, never cached across the lane's lifetime) — a `.followSystemDefault` device switch (Section 7.3) can land on a physically different device with its own calibration entry or none. If the buffer-size property write itself is rejected (a stale entry — the device's real range narrowed since calibration ran — or a rebuild that landed on a device other than the one calibration measured), `CaptureLane` retries once, clamped into that device's *live* `kAudioDevicePropertyBufferFrameSizeRange`, for that session only — a fixable buffer-size mismatch degrades gracefully rather than failing the session, but a clamped value is never written back to the shared store (accepting a property write is weaker evidence than `recommendBufferFrameSize`'s real probe, which also registers and starts an IOProc). Any other failure (permission, tap/aggregate creation) is not buffer-size related and propagates unmodified rather than triggering this retry.
6. **Register the IOProc:** `AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, NULL, block)` — the `NULL` queue puts the callback on the HAL real-time thread; the block captures only the lane's C context pointer (Section 5). The ring buffer and context struct were already allocated and sized (from the step-3 format) *before* this call — nothing allocates after the IOProc exists.
7. **Start:** `AudioDeviceStart(aggID, procID)`. The lane enters `RUNNING` when the first IOProc callback bumps the C context's frame counter — observed by the lane's `DrainLoop`, whose first 50 ms cycle that sees a nonzero frame count reports it to the engine queue. If **no** callback arrives within **2 s** of `AudioDeviceStart`, treat it as a `PREPARING` failure: apply the standard retry rule (one retry after 250 ms, then `FAILED`, Section 8).

Teardown is the exact reverse discipline and is canonical in Section 8; stated once here for orientation: `AudioDeviceStop(aggID, procID)` → `AudioDeviceDestroyIOProcID(aggID, procID)` → `AudioHardwareDestroyAggregateDevice(aggID)` → `AudioHardwareDestroyProcessTap(tapID)`. **Any rebuild is a full teardown followed by a full re-run of steps 1–7** — partial restarts are known-ineffective against Bug B.

### 4.6 Lane multiplicity

Every `SessionSpec` produces exactly **one lane**, slug `mix`: a single global tap with exclusions (Section 3.4). `CaptureEngine` builds it directly — there is no lane-plan computation, since there is nothing left to plan.

An earlier revision of this design supported multiple lanes (`multiTrack`, one `CaptureLane` per selected app, with cross-lane alignment via each segment's first-buffer host time). That mode was removed along with per-app capture (Section 3.4); it is documented here only because `CaptureLane` itself remains a self-contained, independently-rebuildable stack (its own `CATapDescription`, tap, private aggregate device, IOProc, `td_ring_t` ring, `DrainLoop` thread, `SegmentWriter`, and `ZeroWatchdog`) — nothing architecturally prevents `CaptureEngine` from owning more than one again, it just never needs to.

---

## 5. Data Flow

This section traces one sample from the OS mix to bytes on disk, and pins down exactly which thread is allowed to do what. The single lane (`CaptureLane`, Section 4) owns one complete instance of this pipeline.

### 5.1 Thread inventory

There are exactly four **kinds** of execution context. The IOProc thread and DrainLoop Thread are instantiated once, for the single lane; the engine queue and main thread are process-wide. Nothing else may touch capture data.

| Context | Owner / creation | Cadence | Allowed | Forbidden |
|---|---|---|---|---|
| **HAL real-time IOProc thread** (one, for the lane) | Core Audio; delivered because `IOProcHost` passes a NULL dispatch queue to `AudioDeviceCreateIOProcIDWithBlock` | Every device I/O cycle (nominally 512 frames, see Section 4 recipe step 5) | The three operations in §5.2, executed by `SystemAudioRecorderRT` C functions only | Locks, allocation, Swift/ObjC runtime, logging, syscalls, file I/O — anything not in §5.2 |
| **DrainLoop Thread** (one, for the lane) | `DrainLoop`, a dedicated `Thread` at QoS `.userInitiated` | 50 ms poll cycle | Ring reads, vDSP zero-scan and metering, interleave, synchronous `ExtAudioFileWrite`, watchdog bookkeeping, meter-snapshot publication | Any `AudioHardware*` lifecycle call; UI work |
| **Engine queue** (one per process) | `CaptureEngine`'s dedicated serial dispatch queue | Event-driven | All Core Audio object lifecycle (create/start/stop/destroy of taps, aggregates, IOProcs), `ZeroWatchdog` rebuild execution (state transitions run on the drain thread, Section 8), `DeviceObserver` callbacks (dispatched onto it), handing event records to `SessionStore` (which serializes manifest file I/O on its own dedicated serial queue) | Touching ring payload; blocking on the DrainLoop |
| **Main thread** | AppKit/SwiftUI | UI events; 20 Hz meter poll timer | Reading the published meter snapshot, all UI, notifications | Everything else in this section |

The IOProc thread is created, scheduled, and destroyed by the HAL; System Audio Recorder never blocks it, signals it, or joins it. The DrainLoop Thread is started when the lane enters RUNNING and is asked to finish (drain-fully, then exit) when the lane enters STOPPING (Section 8). The engine queue serializes every lifecycle mutation so a rebuild can never race a stop.

### 5.2 The IOProc contract (verbatim, non-negotiable)

IOProc block work, in order, nothing else: (1) read AudioBufferList from `inInputData`; (2) `td_ring_write()` — copy bytes into the SPSC ring (drop-all-or-nothing on overflow, increment atomic `droppedChunks` + `droppedFrames` counters); (3) store `inInputTime->mHostTime` and cumulative frame count into atomics. NO locks, NO allocation, NO Swift/ObjC runtime, NO logging, NO syscalls.

The block captured at registration holds only an unmanaged pointer to a preallocated C context struct (`IOProcHost`, Section 4); every byte the callback touches — ring storage, atomics, scratch constants — was allocated and wired on the engine queue before `AudioDeviceStart`. `td_ring_write()` is strictly a bounded byte copy — it never reorders, converts, or otherwise processes samples. In particular, layout conversion (interleaving of non-interleaved tap buffers) happens exclusively on the DrainLoop Thread (§5.4 step 5), never here. Two timestamp artifacts are maintained in the context: a **write-once `firstHostTime`** latched on the first callback after each (re)start, and a **rolling pair** (`lastHostTime`, `totalFramesCaptured`) — together with `lastBufferFrames`, the frame count of that most recent buffer — published every callback under a small sequence counter so the consumer can read them tear-free (§5.6 needs all three for its gap and rotation formulas).

### 5.3 Ring buffer: `td_ring_t`

A single-producer / single-consumer **byte** ring in the `SystemAudioRecorderRT` C library. One producer (the IOProc thread), one consumer (the DrainLoop Thread) — never more, which is what makes the lock-free design sound.

- **Capacity**: next power of two ≥ 8 seconds × sampleRate × channels × 4 bytes (Float32). Sizing math:
  - 48 kHz stereo: 48,000 × 2 × 4 = 384,000 B/s; × 8 s = 3,072,000 B (≈ 3 MiB) → round up to **4 MiB** (4,194,304 B ≈ 10.9 s real headroom).
  - 192 kHz 8-channel: 192,000 × 8 × 4 = 6,144,000 B/s; × 8 s = 49,152,000 B (≈ 48 MiB) → round up to **64 MiB** (67,108,864 B ≈ 10.9 s real headroom).
- **Indices**: free-running unsigned 64-bit `writeIdx` and `readIdx` (byte counts since start, never wrapped); physical position = index AND (capacity − 1). Free space = capacity − (writeIdx − readIdx). Because indices are free-running, a logical frame may physically straddle the wrap point; copies are therefore "up to two memcpy segments," which keeps whole-frame framing valid for any channel count, including non-power-of-two frame sizes (e.g. 24-byte 6-channel frames).
- **Cache-line layout**: `writeIdx`, `droppedChunks`, `droppedFrames` live on one 64-byte-aligned cache line owned by the producer; `readIdx` lives alone on a second 64-byte-aligned line; immutable fields (buffer pointer, capacity mask, bytesPerFrame) on a third, read-only line. This prevents false sharing between the two threads.
- **Publication ordering** (C11 atomics): producer copies payload bytes first, then stores `writeIdx` with release ordering; consumer loads `writeIdx` with acquire ordering before reading payload, and after copying out stores `readIdx` with release; producer loads `readIdx` with acquire when computing free space. `droppedChunks`/`droppedFrames` are monotonic counters written relaxed by the producer and read as deltas by the consumer.
- **Whole-frame framing**: the payload is raw sample bytes with no headers. The writer only ever writes whole frames; the reader only ever reads whole frames (both sides operate in multiples of bytesPerFrame), so the logical stream is always frame-aligned. In planar mode both sides additionally operate in multiples of one whole callback chunk — itself a whole-frame multiple — per the layout rule in the next bullet.
- **Tap-native-layout-in-ring invariant**: the ring always contains the tap ASBD's **native layout**, and `td_ring_write` is always a plain bounded byte copy — never a sample reordering. Interleaving is the DrainLoop Thread's job (§5.4 step 5), per the fidelity rules in Section 7. Two cases:
  - **Interleaved tap format** (the expected case — `kAudioTapPropertyFormat` reports interleaved Float32): the AudioBufferList carries one buffer; `td_ring_write` copies its bytes verbatim. Any whole-frame count is accepted; no chunk-boundary knowledge is needed downstream, and drain step 5 is a no-op.
  - **Non-interleaved (planar) tap format** (not expected in practice now that `matchDeviceLayout` and per-app capture are gone, Section 3.4 — the only tap System Audio Recorder builds is the global stereo-mixdown tap, which reports interleaved Float32; this path is retained defensively in case that assumption ever proves wrong on some device/OS combination): the AudioBufferList carries one buffer per channel plane. `td_ring_write` copies the planes **back-to-back in channel order** (all of plane 0's bytes, then all of plane 1's, …) as one all-or-nothing chunk — still plain sequential byte copies, one per plane, with no per-sample striding. The chunk's byte count is frames × channels × 4 = a whole-frame multiple, so the byte-level framing invariant is preserved. **Deterministic parseability rule**: in planar mode every ring chunk is exactly `framesPerCallback` frames, where `framesPerCallback` = the aggregate's `kAudioDevicePropertyBufferFrameSize` (the calibrated buffer size, 512 fallback if never calibrated; Section 4 recipe step 5), recorded in the C context at lane build. The drain therefore reads and deinterleaves in exact multiples of one callback chunk (framesPerCallback × channels × 4 bytes) with no headers in the stream. If a planar-mode callback ever delivers a different frame count (not expected from a HAL IOProc running with a fixed buffer frame size), the producer must not write an unparseable chunk: it drops the whole chunk via the standard drop-all-or-nothing path (`droppedChunks` += 1, `droppedFrames` += chunk frames; the drain logs the resulting `overrunGap` event, §5.4 step 7).
- **Overflow — drop-all-or-nothing**: before copying, the producer computes free space; if the incoming chunk does not fit **entirely**, nothing is written: `droppedChunks` += 1, `droppedFrames` += chunk frame count. Partial frames or partial chunks are never written, so the ring can never contain a torn frame. The drain detects counter deltas and logs `overrunGap` events (§5.4 step 7).

### 5.4 Drain cycle, step by step

Every 50 ms the DrainLoop Thread wakes and runs this sequence to completion:

1. **Snapshot**: acquire-load `writeIdx`; available bytes = writeIdx − readIdx, truncated down to whole frames.
2. **Chunked copy-out**: loop until the ring is empty, copying at most **1 second of frames per chunk** (per-chunk cap bounds the preallocated scratch buffer — sized at lane build to 1 s × rate × channels × 4 B — and keeps post-stall catch-up incremental). In planar mode the copy-out length is additionally truncated down to a whole number of callback chunks (framesPerCallback × channels × 4 bytes each, §5.3) so plane boundaries are never split. Each chunk is copied out of the ring (up to two memcpy segments across the wrap), then `readIdx` is release-stored immediately so the producer regains space before the chunk is processed.
3. **Exact-zero scan** (vDSP): compute the maximum magnitude over the whole chunk (vDSP max-magnitude reduction). If it equals 0.0 **exactly**, the chunk is all-zero; −0.0 has magnitude 0.0 and therefore counts as zero. Any nonzero magnitude resets the zero-run clock. The consecutive all-zero duration (frames ÷ rate, in seconds) is the primary input to `ZeroWatchdog` (Section 8).
4. **Meters** (vDSP): per-channel peak (max magnitude) and RMS over the chunk; set a clip flag when any sample ≥ 1.0 (the UI holds its clip indicator 2 s; the master keeps >1.0 float values untouched — Section 3/Section 6).
5. **Interleave if needed** (drain-side, per the fidelity rules in Section 7): if the tap ASBD is non-interleaved, the bytes copied out in step 2 are a sequence of plane-major callback chunks of exactly framesPerCallback frames each (§5.3); the drain reorders each callback chunk into interleaved frames in a second preallocated scratch buffer — a pure per-sample reordering, bit-exact, no arithmetic. In the expected interleaved case this step is a no-op. This is the **only** place in the pipeline where layout conversion occurs; the IOProc never reorders samples (§5.2).
6. **Write**: synchronous `ExtAudioFileWrite` of the chunk into the current CAF segment via `SegmentWriter`. Client ASBD and file ASBD are identical (Float32, interleaved, tap-native rate), so no AudioConverter is engaged and no sample can change (Section 6). Synchronous writing is deliberate: the ~8 s ring absorbs disk stalls, and backpressure is observable as ring fill rather than hidden queue growth.
7. **Watchdog and gap bookkeeping**: feed zero-run seconds and "callbacks fresh?" into `ZeroWatchdog`, whose state machine runs **locally on this thread** — zero-run accounting and all state transitions execute on the drain thread (Section 8); diff `droppedChunks`/`droppedFrames` against the last cycle. The drain thread itself never writes the manifest and never performs lifecycle actions: it posts only (a) rebuild requests and (b) event records (overrun deltas with host time and frames lost) onto the engine queue, where `SessionStore`'s API persists them (the actual manifest file I/O is serialized on `SessionStore`'s own dedicated serial queue); ≥ 3 overrun events within 60 s raises the UI warning "Disk can't keep up — check free space / other I/O." (Full policy in Section 8.)
8. **Meter snapshot publication**: write {per-channel peak, RMS, clip flag, zero-run s, dropped totals, frame position} into the lane's single atomic snapshot slot, guarded by a seqlock-style version counter (writer increments to odd, writes, increments to even; reader retries on odd/changed versions). The main thread polls this slot at 20 Hz; the drain never calls into UI.

Then the thread sleeps for the remainder of the 50 ms cycle. On STOPPING, the loop runs steps 1–7 until the ring is empty, then hands off to FINALIZING (Section 8).

### 5.5 Buffer handoff diagram

```
        Core Audio system mix (Float32 @ device nominal rate)
                      │ process tap → private aggregate (Section 4)
                      ▼
┌── HAL real-time IOProc thread (per lane; owned by the HAL) ──────────┐
│ (1) read AudioBufferList  (2) td_ring_write()  (3) publish           │
│     mHostTime + cumulative frames (seqlock atomics)                  │
└─────────────┬────────────────────────────────────────────────────────┘
              │ payload memcpy, then release-store writeIdx
              ▼
      ┌─────────────────────────────┐  producer line: writeIdx,
      │  td_ring_t  (SPSC byte ring)│    droppedChunks/droppedFrames
      │  pow2: 4 MiB @48k/2ch,      │  consumer line: readIdx
      │        64 MiB @192k/8ch     │  whole frames only, no headers
      └─────────────┬───────────────┘
                    │ acquire-load writeIdx; copy ≤1 s chunks;
                    │ release-store readIdx
                    ▼
┌── DrainLoop Thread (per lane, .userInitiated, 50 ms cycle) ──────────┐
│ zero-scan → meters → interleave-if-needed → ExtAudioFileWrite        │
│ → watchdog/gap bookkeeping → seqlock meter snapshot                  │
└──────┬─────────────────────────────────────┬─────────────────────────┘
       │ synchronous write                   │ snapshot slot
       ▼                                     ▼
 <lane-slug>/segment-NNN.caf          main thread UI polls @ 20 Hz
 (SegmentWriter, Section 6)           (meters, health chip)

 engine queue (serial, process-wide): lifecycle only — create/start/
 stop/teardown, ZeroWatchdog rebuild execution, DeviceObserver events,
 handing event records to SessionStore. Never touches ring payload.
```

### 5.6 Host timestamps: capture points and uses

Captured only on the IOProc thread, consumed everywhere else:

- **`firstHostTime`** (write-once per start/rebuild) becomes the segment's `startHostTime` in `session.json` **only for segments opened at lane start or by a rebuild-driven rotation** — device switch and rate change both rotate via full teardown/rebuild (Section 7, Section 8), so the first post-rebuild callback latches a fresh `firstHostTime` that the drain latches into the segment it then opens. **Cap-based rotations** (user-set max duration/size caps, Section 6) involve no rebuild, so no new `firstHostTime` is latched and the stale value from the last (re)start must NOT be reused — it would be wrong by up to a full segment and break cross-lane alignment. Instead, on a cap-based rotation the drain derives the new segment's `startHostTime` from the rolling values at the rotation boundary: read (`lastHostTime`, `lastBufferFrames`, `totalFramesCaptured`) tear-free via the sequence counter (§5.2); `lastHostTime` marks the first frame of the most recent callback buffer, i.e. absolute frame index `totalFramesCaptured − lastBufferFrames`; with S = the absolute frame index of the first frame written into the new segment, set `startHostTime` = `lastHostTime` + (S − (`totalFramesCaptured` − `lastBufferFrames`)) ÷ sampleRate, converted from seconds to host-time ticks via the mach timebase. This keeps every segment's manifest entry equal to the true host time of its own first frame — the property multi-lane alignment (point (c) below) depends on. For every segment, however its `startHostTime` was obtained, the paired `startWallTime` is that `startHostTime` mapped through the hostTime↔wall-clock correlation sampled once on the engine queue at lane start.
- **Rolling (`lastHostTime`, `totalFramesCaptured`)** feeds three consumers: (a) **gap accounting** — `mHostTime` marks the *start* of a callback's buffer, whose frames were already captured, so a rebuild's gap is measured from the **end** of the last delivered buffer: gap = firstHostTime-after-rebuild − (lastHostTime-before-teardown + lastBufferFrames ÷ sampleRate). It is recorded as `gapMs` and, under `preserveWallClock`, converted into exactly that many silence frames by the writer (Section 8); `overrunGap` events use it the same way; (b) **liveness** — if the rolling timestamp goes stale > 1 s while RUNNING, callbacks have stopped entirely (device died/removed), which routes to `DeviceObserver` handling rather than the Bug-B path, since Bug B keeps callbacks firing with valid timestamps; (c) **multi-lane alignment** — lanes on the same device share the device clock, so editors align tracks by differencing each lane's per-segment `startHostTime` values from the manifest (Section 4/Section 6).

---

## 6. File Format & Storage Design

### 6.1 Master format: CAF, Float32, interleaved — and exactly why

Every master (archival) recording System Audio Recorder makes is a **Core Audio Format (CAF) file containing 32-bit float, interleaved, packed linear PCM at the tap-native sample rate** (see Section 7 for how that rate is determined). This is non-negotiable, for four reasons:

1. **The float-in-WAV truncation bug.** Known Core Audio bug (established research fact, quoted verbatim): "requesting 32-bit float samples written into a WAV container (via AVAudioFile or ExtAudioFile) can silently get truncated/converted to Int32." Silent — no error is returned; the file simply is not float anymore. WAV is therefore **never** used as a master or capture format anywhere in System Audio Recorder. WAV appears only as a 24-bit integer *compatibility export* (Section 6.6), and the export UI copy must state why WAV is not offered as a float master, citing this bug.
2. **64-bit chunk sizes.** CAF chunk sizes are 64-bit, so there is no 4 GB file-size ceiling. Long sessions at high rates (192 kHz, 8 channels) run for hours without forced rotation. A 4 GB+ single-segment test is mandatory (see Section 10).
3. **Unknown-size data chunk = crash-safe streaming.** The CAF `data` chunk's size field may legally be written as **-1** ("unknown size"), which makes the file a valid streaming CAF readable to end-of-file at all times. System Audio Recorder writes every segment this way while recording and patches the real size and frame count only at finalization. If the app or machine dies mid-recording, the segment on disk is already a playable file (see Section 6.5).
4. **Native Core Audio container.** CAF is Core Audio's own format: ExtAudioFile writes it with zero format impedance, every Apple tool reads it, and no third-party codec code is needed.

**AIFC is the permitted-but-not-chosen fallback.** AIFC also carries float PCM safely and is acceptable per the research constraints, but it lacks CAF's 64-bit sizes and the documented -1 streaming-data-chunk behavior. The decision is CAF; AIFC exists in this document only as the sanctioned escape hatch if a real-world CAF blocker appears during implementation.

### 6.2 SegmentWriter contract

`SegmentWriter` (module defined in Section 4) owns all master-file I/O for one `CaptureLane`. It runs exclusively on that lane's `DrainLoop` thread — never on the real-time IOProc thread (Section 5).

**The one iron rule: identical client and file ASBDs.** SegmentWriter opens each segment with `ExtAudioFileCreateWithURL` using file type `kAudioFileCAFType` and a file-side `AudioStreamBasicDescription` built *from the tap format read via `kAudioTapPropertyFormat`* (Section 7.2). **Single exception:** when the advanced "Force capture rate" mode is enabled (Section 7.6), the file-side ASBD is built from the aggregate input stream's virtual format (`kAudioStreamPropertyVirtualFormat`, asserted Float32 at the forced rate R) instead of the tap format — in that mode the virtual format *is* the effective IOProc format. Everything else in this rule is identical in both modes. It then sets `kExtAudioFileProperty_ClientDataFormat` to the **byte-identical same ASBD**. When client format == file format, ExtAudioFile engages no AudioConverter: writes are straight memcpy-grade block writes, and there is no code path on which sample-rate conversion, dither, bit-depth change, or the float→Int32 truncation bug can occur.

The canonical ASBD (both sides, identical):

| Field | Value |
|---|---|
| `mSampleRate` | effective IOProc rate (Float64): tap-native rate from `kAudioTapPropertyFormat`, or in forced-rate mode the forced rate R from the aggregate stream's virtual format (Section 7.6); e.g. 48000.0 |
| `mFormatID` | `kAudioFormatLinearPCM` |
| `mFormatFlags` | `kAudioFormatFlagIsFloat \| kAudioFormatFlagIsPacked` (native-endian; **no** `kAudioFormatFlagIsNonInterleaved`) |
| `mChannelsPerFrame` | lane channel count (2 — the global tap is always a stereo mixdown) |
| `mBitsPerChannel` | 32 |
| `mBytesPerFrame` | 4 × `mChannelsPerFrame` |
| `mFramesPerPacket` | 1 |
| `mBytesPerPacket` | = `mBytesPerFrame` |

If the tap delivers non-interleaved buffers, the DrainLoop interleaves them (pure bit-exact reordering, Section 5) *before* handing frames to SegmentWriter; SegmentWriter itself only ever sees interleaved Float32.

**Bit-exact write/read-back self-check.** This check runs automatically at **every launch of the app and of the CLI, in all builds** — it is not debug-only (shipped from Phase 2 onward): generate a known 1-second Float32 pattern buffer (deterministic, covering positive/negative/denormal/±0.0/>1.0 values), write it through SegmentWriter to a temporary CAF in the scratch area, read it back with ExtAudioFile using the same ASBD, and assert **bit-exact equality** (memcmp of the raw sample bytes). Any mismatch is a fatal configuration regression: log at fault level, surface an error UI, and the product **refuses to record** until the check passes. A `diag` subcommand is the manual entry point for running the same check on demand. This guards permanently against any float-truncation regression in the file layer.

**Write behavior.** `ExtAudioFileWrite` is called synchronously on the DrainLoop thread in chunks of ≤ 1 s of frames; the 8-second ring buffer absorbs disk stalls (Section 5). The `data` chunk is written with size -1 for the life of the segment. **Finalization** (segment rotation or session stop): flush pending writes, `ExtAudioFileDispose` (which patches the real data-chunk byte size and frame count), then record the result in the manifest (`segments[].frames`, `segments[].finalized = true`) via the write chain in Section 6.4.

**Rotation** (triggers in Section 6.3): finalize the current segment, then immediately open `segment-<next>.caf` with a freshly derived ASBD (the rate/channels may have changed — that is often *why* we rotated). Segment numbering continues per lane; it never resets within a session.

### 6.3 On-disk layout

- **Recordings root:** `~/Music/System Audio Recorder/` (user-configurable in Settings → General). Session folders are direct children of the root.
- **Session folder name template** (configurable; default): `{date} {time} — {source}` → e.g. `2026-07-14 09.41.03 — Spotify`.
  - Tokens: `{date}` = local date `YYYY-MM-DD`; `{time}` = local time `HH.MM.SS` (dots, not colons — colons are illegal in macOS filenames); `{source}` / `{app}` = always "System Audio"; `{device}` = target device name; `{rate}` = nominal rate at session start formatted as `48kHz` / `44.1kHz` / `192kHz`.
  - Sanitization: replace `/`, `:`, and control characters with `-`; collapse runs of whitespace; trim; cap at **200 bytes of UTF-8** (bytes, not characters — truncate only at a character boundary so no code point is split). On collision, append ` (2)`, ` (3)`, ….
- **Inside a session folder:**
  - One subfolder for the lane, named `mix` (the only lane slug there is).
  - Segments: `<lane-slug>/segment-001.caf`, `segment-002.caf`, … — zero-padded to 3 digits (widening naturally past 999), 1-based, monotonically increasing per lane.
  - `session.json` — the manifest (Section 6.4).
  - `.recording.lock` — advisory liveness lock containing the writer process's PID; present only while a recording process holds the session open (created/removed per Section 6.5).
  - `exports/` — created on first export; transcodes mirror the lane structure: `exports/<lane-slug>/segment-001.flac` etc. Exports never overwrite: collisions get ` (2)` suffixes.
- **Segment rotation triggers:** (a) device switch (Section 7.4/7.5), (b) sample-rate change (Section 7.3), (c) optional user-set max-duration/max-size caps (Settings → Recording; **default OFF**). Bug-B watchdog rebuilds do **not** rotate — the writer and current segment stay open across rebuilds (Section 8).

### 6.4 `session.json` manifest — schema v1, field by field

One JSON object per session. All timestamps are ISO-8601 strings with milliseconds and timezone offset (e.g. `"2026-07-14T09:41:03.217-07:00"`). All paths are relative to the session folder, using `/` separators.

**Top level**

| Field | Type | Semantics |
|---|---|---|
| `schemaVersion` | integer | Always `1` for this document. Readers must reject higher versions gracefully. |
| `app` | object | `{name: string, version: string, build: string}` — CFBundleName, CFBundleShortVersionString, CFBundleVersion of the writer (GUI or CLI). |
| `os` | object | `{version: string, build: string}` — e.g. `{"version": "26.0.1", "build": "25A5xxx"}`. |
| `session` | object | See below. |
| `lanes` | array | One entry per `CaptureLane`, ordered by `index`. |

**`session` object**

| Field | Type | Semantics |
|---|---|---|
| `id` | string | UUID (v4), generated at session creation. Stable identity independent of folder renames. |
| `title` | string | The expanded folder-name template at creation time (display name). |
| `createdAt` | string | Timestamp of session creation. |
| `finalizedAt` | string \| null | Set when FINALIZING completes (Section 8), or by the crash-recovery scan (which also sets `recovered: true`; Section 6.5). **Null/absent means the session is unfinalized — the crash marker** that drives the recovery scan. |
| `recovered` | boolean | Absent or `false` normally; set `true` by the crash-recovery scan. |
| `sourceType` | string | Always `"systemMix"`. |
| `device` | object | `{uid: string, name: string}` — initial target output device. |
| `deviceHistory` | array | Entries `{uid: string, name: string, fromWallTime: string}`; the initial device is entry 0; a new entry is appended on every `deviceSwitch`. |
| `timelinePolicy` | string | `"preserveWallClock"` \| `"compressTimeline"` (Section 8 defines the behaviors). |

**`lanes[]` entries**

| Field | Type | Semantics |
|---|---|---|
| `index` | integer | 0-based lane index. |
| `slug` | string | Lane slug per Section 6.3; equals the lane's subfolder name. |
| `processes` | array | Always empty — the lane is a global tap, not a set of resolved target processes. |
| `calibration` | object \| null | `{deviceUID: string, gainCompensationDB: number, measuredAt: string}` — the Bug-A profile matching the lane's current device, or `null` if none (Section 8). Updated on device switch. Master audio is NEVER modified by this value; it is metadata for meters and export. |
| `segments` | array | See below. |
| `events` | array | See below. |

**`segments[]` entries**

| Field | Type | Semantics |
|---|---|---|
| `index` | integer | 1-based; matches the filename number. |
| `file` | string | Relative path, e.g. `"mix/segment-001.caf"`. |
| `startWallTime` | string | Wall-clock time of the first frame written to this segment. |
| `startHostTime` | string | Host time of the segment's first frame — equal to the first IOProc buffer's `mHostTime` for segments opened at lane start or after a rebuild/device/rate rotation; for cap-based rotations it is derived per Section 5.6 (the boundary can fall mid-buffer). Stored as mach_absolute_time ticks in a **decimal string** (u64 values can exceed JSON's 2^53 safe-integer range). This is the cross-lane alignment anchor (Section 4). |
| `sampleRate` | number | The segment's rate in Hz (per-segment because rotation happens on rate change). |
| `channels` | integer | Interleaved channel count of the file. |
| `frames` | integer \| null | Total frames; `null` until finalized or recovered. |
| `finalized` | boolean | `true` once the CAF sizes are patched. |

**`events[]` entries** — uniform shape: `{type, atWallTime, framePosition, gapMs, details}`.

| Field | Type | Semantics |
|---|---|---|
| `type` | string | `"zeroDropoutRebuild"` \| `"overrunGap"` \| `"deviceSwitch"` \| `"rateChange"` \| `"waitingForDevice"` \| `"error"`. |
| `atWallTime` | string | When the event occurred. |
| `framePosition` | integer | Lane-cumulative frame count at the event. |
| `gapMs` | number \| null | Audio gap attributable to the event; `null` when not applicable. |
| `details` | object | Per-type payload: `zeroDropoutRebuild` → `{attempts: integer}`; `overrunGap` → `{framesLost: integer, chunks: integer}`; `deviceSwitch` → `{fromUID, toUID, fromName, toName}`; `rateChange` → `{fromRate, toRate}`; `waitingForDevice` → `{deviceUID: string, resumed: boolean}`; `error` → `{osStatus: integer, context: string}`. |

**Write policy.** Manifest ownership follows one chain, and the drain thread never writes the manifest itself: the drain thread enqueues event records onto the engine queue; engine-queue code calls `SessionStore`; and `SessionStore` serializes the actual manifest file I/O on its own dedicated serial queue. Every write is atomic: serialize to `session.json.tmp` in the session folder, then `rename(2)` over `session.json`. Rewrite on: session start, lane start, segment open, segment finalize, each event append, and finalization — coalesced so the file is rewritten at most once per second during event storms.

### 6.5 Crash-recovery scan

At every launch (GUI and CLI), `SessionStore` scans the recordings root. **Liveness guard first.** The GUI and CLI are independent processes with no IPC, and both can record (Section 3) — so a session whose `finalizedAt` is null is not necessarily crashed: the *other* process may be writing it right now, and "recovering" a live session would truncate and patch files mid-write (data corruption). Before any recovery action, every candidate session folder must pass BOTH guards:

- **Advisory lock file.** Every recording process creates `<session-folder>/.recording.lock` when the session folder is created (before the first segment opens), containing its own PID as decimal ASCII text. It is removed during session-level finalization: after **all** lanes have finished their per-lane finalization, `CaptureEngine` — on the engine queue — writes the session-level `finalizedAt`, removes `.recording.lock`, and fires the `onSessionFinalize` hook, **exactly once per session** regardless of lane count (Section 8); no individual lane performs these session-level steps. The scanner reads `.recording.lock`: if the file exists and the named PID is alive (signal-0 probe — `kill(pid, 0)` succeeds or fails with `EPERM`), the session is **live: skip it entirely**. If the PID is dead (`ESRCH`) or the file is absent/unparseable, continue to the next guard.
- **Recency check (PID-reuse belt-and-braces).** Skip the session anyway if its `session.json` **or** its most recently modified segment file has a modification time within the last **30 seconds**. A genuinely crashed session simply gets recovered on the next launch instead; this closes PID-reuse races and any window where a lock file is missing while writes are still landing.

**CAF byte layout the recovery patch relies on (self-contained — the implementer has no external spec available):**

- A CAF file begins with an 8-byte file header: 4 bytes ASCII `caff`, then a big-endian UInt16 file version (`1`), then a big-endian UInt16 file flags (`0`).
- After the header, the file is a sequence of chunks. Each chunk is: 4-byte ASCII chunk type, 8-byte **big-endian signed Int64** chunk size (counting only the payload that follows — NOT the 12-byte type+size chunk header itself), then the payload.
- To locate the audio data, walk chunks starting at file offset 8: read each 12-byte chunk header, and if the type is not `data`, skip forward `chunkSize` payload bytes to the next header. Only the `data` chunk may carry size −1 ("unknown"), and only when it is the last chunk in the file — which is exactly how SegmentWriter leaves an unfinalized segment (Section 6.1/6.2), so the walk terminates at `data` with everything from there to EOF belonging to it.
- The first chunk in files SegmentWriter produces is the mandatory `desc` chunk (32-byte payload, all fields big-endian): Float64 `mSampleRate`, 4-byte `mFormatID` (`lpcm`), UInt32 `mFormatFlags`, UInt32 `mBytesPerPacket`, UInt32 `mFramesPerPacket`, UInt32 `mChannelsPerFrame`, UInt32 `mBitsPerChannel`. For our LPCM segments `mFramesPerPacket = 1`, so `mBytesPerFrame = mBytesPerPacket`.
- Define `dataPayloadOffset` = the file offset of the first payload byte of the `data` chunk (immediately past its 12-byte chunk header). **Crucially, the `data` chunk payload does not begin with audio:** its first 4 bytes are the big-endian UInt32 `mEditCount` field. The audio bytes start at `dataPayloadOffset + 4` — that offset is the frame-alignment origin for every computation below.
- Therefore: `audioDataBytes = fileLength − (dataPayloadOffset + 4)`, and the correct patched value for the `data` chunk's size field is `fileLength − dataPayloadOffset` (it counts `mEditCount` plus the audio bytes), written as big-endian Int64 at offset `dataPayloadOffset − 8`. Computing `audioDataBytes` from the raw chunk size or from `fileLength − dataPayloadOffset` (forgetting the 4-byte `mEditCount`) yields an off-by-4 frame count and a truncation boundary that is not actually frame-aligned — the exact failure this spec exists to prevent.

For each session folder that passes both guards:

1. If its `session.json` has `finalizedAt` null/absent: mark it **Recovered** — set `session.recovered = true`, set `finalizedAt` to the recovery time, and delete any stale `.recording.lock`.
2. For each unfinalized segment in that session: locate the `data` chunk and compute `dataPayloadOffset` and `audioDataBytes` per the layout above, taking `mBytesPerFrame` from the manifest (`segments[].channels` × 4 for Float32) or, if the manifest entry is missing, from the segment's own `desc` chunk. If `audioDataBytes` is not a whole multiple of `mBytesPerFrame` (mid-frame crash), truncate the file to `(dataPayloadOffset + 4) + floor(audioDataBytes / mBytesPerFrame) × mBytesPerFrame` and recompute `audioDataBytes` from the new file length. Patch the `data` chunk's size field (big-endian Int64 at `dataPayloadOffset − 8`) to `fileLength − dataPayloadOffset`; compute `frames = audioDataBytes / mBytesPerFrame`; set `segments[].frames` and `finalized = true`. (A −1-size CAF is readable even unpatched; patching just makes it a fully normal file.)
3. Compute and store session duration from the recovered segments; the Library shows the session with a "Recovered" health badge (Section 3).
4. A session folder containing `.caf` segments but **no** `session.json` (crash before the first manifest write) gets a minimal reconstructed manifest from directory contents (`schemaVersion`, `session{id: new UUID, title: folder name, recovered: true}`, lanes/segments inferred from files), so no audio is ever orphaned. Both liveness guards above apply to these folders too — the `.recording.lock` file exists before the first segment opens, so even a pre-manifest live session is protected.

### 6.6 Export formats summary

All exports are produced by `ExportService`, always **from the CAF float master, never by re-capture**, via ExtAudioFile/AudioConverter. Sample rate is NEVER changed on export in v1 (no SRC anywhere in the product). Optional gain compensation (a single float scalar multiply from the stored Bug-A profile; default ON when a profile exists) is specified in Section 8.

| Format | Container/ext | Codec | Bit depths | Notes |
|---|---|---|---|---|
| FLAC | `.flac` | `kAudioFormatFLAC` | 16- or 24-bit int | Lossless-compressed derivative. |
| ALAC | `.m4a` | `kAudioFormatAppleLossless` | 16- or 24-bit int | Lossless-compressed derivative. |
| AAC | `.m4a` | AAC ~256 kbps VBR | — | Lossy convenience export. |
| WAV | `.wav` | LPCM int | 24-bit only | **Compatibility export ONLY — never a master.** UI copy notes WAV is not offered as a float master due to the documented float→Int32 truncation bug (Section 6.1). |

Bit-depth reduction rules: 24-bit = plain rounding (transparent); 16-bit = TPDF dither **default ON** (toggle exposed in Settings → Formats & Export). Because floats can legally exceed ±1.0 and the master preserves such values, exports to int hard-clip at full scale — the export UI shows a clip count whenever any sample clipped. Get the compensation interaction right, because the intuition is easy to invert: `gainCompensationDB` is always a non-negative **boost** (Section 8 formula; Bug-A only ever *attenuates*), so "Apply level compensation" can only **increase** int-export clipping risk — a compensated export may push samples that were within ±1.0 over full scale. Compensation never prevents clipping, and Bug-A attenuation is never the cause of clipping (an attenuated master is *less* likely to exceed ±1.0). When the clip count is nonzero, the remedies the export UI offers are: re-export with "Apply level compensation" **OFF** (raw captured level), or knowingly accept the clipped result. Clipping can also occur with compensation entirely off, when the float master itself legitimately exceeds ±1.0 (hot system mix, Gibbs overshoot from the OS ingestion filter) — the live clip indicator (Section 3) flags this during capture.

**Lossless honesty rules (required UI copy, verbatim intent):** FLAC and ALAC decode bit-identically to the integer PCM they encoded — but a 16- or 24-bit export is a *bit-depth reduction of the float master*, so no export is bit-identical to the master. **The CAF master is the only true archive.** Export UI and documentation must say this explicitly; never label an export "identical to the recording."

---

## 7. Sample-Rate & Device-Matching Strategy

### 7.1 The governing fact

macOS does **not** auto-switch a physical output device's sample rate to match content. If the device runs at a different rate than the source material, the OS resamples *before the tap ever sees the audio*, and nothing System Audio Recorder does downstream can undo that. Therefore the only fidelity-correct capture rate is **whatever rate the target output device is actually running at right now**. System Audio Recorder never assumes, never hardcodes, and never prefers 44.1 kHz or 48 kHz; any literal rate constant in the capture path is a code-review reject (tests in Section 10 cover this).

### 7.2 Lane-start procedure (rate resolution)

Performed on the engine queue as part of PREPARING (creation recipe in Section 4):

1. Resolve the target output device `AudioObjectID`: for `.followSystemDefault`, read `kAudioHardwarePropertyDefaultOutputDevice`; for `.fixed(deviceUID)`, enumerate `kAudioHardwarePropertyDevices` and match each device's `kAudioDevicePropertyDeviceUID` string exactly. (CLI `--device <uid|name>`: the argument is matched first as an exact device UID, then as a **case-insensitive** device name; a name matching more than one device exits 3 and lists the matching UIDs on stderr — Section 3.8 owns this matching rule.) If a `.fixed(deviceUID)` device is absent at lane start (GUI path), the lane goes PREPARING → FAILED with a "device not found" error — WAITING_FOR_DEVICE (Section 7.5) applies only to devices lost while RUNNING; on the CLI path this is the exit-code-3 case above.
2. Read the device's `kAudioDevicePropertyNominalSampleRate` (Float64) and output channel count. This nominal rate is the *expected* capture rate.
3. Create the tap, then read `kAudioTapPropertyFormat`. **This ASBD is ground truth** for the bytes the IOProc will deliver — expected Float32 at the device nominal rate.
4. Assert `tapFormat.mSampleRate == nominalRate`. On mismatch: log at error level with both values, **trust the tap format**, and proceed. The tap format — not the device property, not any configuration value — is what sizes the ring buffer (Section 5 formula) and builds SegmentWriter's ASBDs (Section 6.2). **Single exception — forced-rate mode (Section 7.6):** when "Force capture rate" is enabled, the effective IOProc format is the aggregate input stream's virtual format (`kAudioStreamPropertyVirtualFormat`, asserted Float32 at the forced rate R), and *that* ASBD replaces the tap format for ring sizing and SegmentWriter's ASBDs; in every other mode the tap format governs.

The per-segment `sampleRate` and `channels` recorded in the manifest (Section 6.4) always come from the effective IOProc format actually in force for that segment (the tap format normally; the aggregate stream's virtual format in forced-rate mode, Section 7.6).

### 7.3 Rate changes mid-session

`DeviceObserver` installs a property listener for `kAudioDevicePropertyNominalSampleRate` on the currently tapped device, dispatching onto the engine queue. When the rate changes while a lane is RUNNING:

1. Log a `rateChange` event to the manifest: `details = {fromRate, toRate}` (Section 6.4).
2. **Full lane rebuild** — strict teardown then full recreation per Section 8 (partial restarts are never used) — re-running the Section 7.2 procedure so the new tap format is re-read from scratch. The ring buffer is reallocated to the Section 5 capacity formula at the new rate as part of recreation.
3. **Segment rotation**: finalize the current segment, open the next one at the new rate (Section 6.2/6.3). A CAF file never contains mixed rates; per-segment `sampleRate` in the manifest lets any consumer reconstruct the timeline.

There is no sample-rate conversion anywhere in this path — a rate change simply means subsequent segments are different-rate files.

### 7.4 Device policy: `.followSystemDefault` (default)

`DeviceObserver` listens for `kAudioHardwarePropertyDefaultOutputDevice`. When the default output changes (AirPods connect, display speakers appear, user switches in Control Center):

1. Log a `deviceSwitch` event (`details = {fromUID, toUID, fromName, toName}`) and append the new device to `session.deviceHistory`.
2. Full lane rebuild targeting the new device (Section 7.2 from step 1) + segment rotation.
3. **Re-evaluate the Bug-A heuristic** for the new device: if it exposes > 2 output channels, surface the attenuation warning badge (Section 8). Load the calibration profile keyed `(deviceUID, outputChannelCount, macOSBuild)` if one exists and update the lane's `calibration` manifest field (or set it `null`).

If the current default device *disappears*, macOS immediately promotes a new default, which fires this same listener — so `.followSystemDefault` never enters WAITING_FOR_DEVICE; it just switches.

Device/rate notifications can arrive in bursts (a single AirPods connection can fire several listeners within milliseconds). `DeviceObserver` coalesces: after the first notification, wait **500 ms** and act once on the final observed state; identical back-to-back states are ignored. One rebuild, one rotation, one event per real-world change.

### 7.5 Device policy: `.fixed(deviceUID)` and WAITING_FOR_DEVICE

With a fixed device, System Audio Recorder follows that device's rate changes (Section 7.3) but never follows the system default. (A fixed device that is already absent at lane start never reaches this state — that is a PREPARING → FAILED "device not found" error, Section 7.2.) If, while the lane is RUNNING, `DeviceObserver`'s device-list listener reports the fixed device gone (unplugged, Bluetooth drop):

1. Drain the ring fully, finalize the current segment (protecting all captured audio), and move the lane to **WAITING_FOR_DEVICE** (state machine in Section 8). On entry the lane immediately performs the full strict teardown of the dead device's objects (Section 8 order; the destroy calls tolerate non-noErr results from an already-gone device), so if the device returns only the rebuild half remains to run. The session and manifest stay open; the UI health chip shows "◌ Waiting for device"; a `waitingForDevice` event is logged with `details = {deviceUID, resumed: false}`.
2. Wait up to `waitForDeviceTimeout` — **default 5 minutes**, configurable (Settings → Recording). While waiting, each device-list-changed notification re-checks for a device whose UID matches.
3. **Device returns within the timeout:** full rebuild against it + new segment + resume RUNNING; update the event to `resumed: true` and set its `gapMs` from wall-clock delta. The gap lives *between* segments — no silence is inserted regardless of `timelinePolicy` (the in-segment silence-fill of `preserveWallClock` applies to same-segment gaps — Bug-B rebuilds and ring overruns; Section 8); consumers reconstruct timing from per-segment `startWallTime`/`startHostTime`.
4. **Timeout expires:** finalize the session gracefully (normal FINALIZING path, Section 8) and post a UserNotifications alert ("Recording stopped: <device> did not return within <timeout>.", with <timeout> templated from the configured `waitForDeviceTimeout`).

### 7.6 Forced-rate advanced mode ("Force capture rate")

An ADVANCED setting, **default off** (Settings → Advanced). It exists purely for convenience workflows that require one fixed rate across device switches; it is a deliberate fidelity trade-off. The setting must display this warning verbatim wherever it is enabled:

> "Forcing a rate different from the output device's current rate makes macOS resample the audio before System Audio Recorder can capture it. Only use this if you need a fixed rate more than you need maximum fidelity."

**Mechanism (UNVERIFIED — full entry in Open Risks, Section 11).** Behavior when enabled with rate R:

- After creating the private aggregate device (recipe step 4, Section 4), set `kAudioDevicePropertyNominalSampleRate = R` on the **aggregate device**. Be honest about what this does: an aggregate device's supported rates are the intersection of its sub-devices' rates, and setting the aggregate's nominal rate **propagates to its sub-devices** — including the real physical output device that is the aggregate's main sub-device and clock master (Section 4 recipe). The expected outcome is therefore either (a) success, which **changes the user's physical output device to R Hz** — audible to every other app on the system — or (b) failure, if the physical device does not support R. Note that `kAudioSubTapDriftCompensationKey = true` (already in the recipe) only corrects clock drift between devices running at the same nominal rate; it does **not** decouple the aggregate's rate from its main sub-device. This design makes no "System Audio Recorder won't touch your device configuration" promise in forced-rate mode — it cannot.
- **Required UI disclosure**, shown alongside the verbatim resampling warning both when the mode is enabled and at record start while it is active: "Force capture rate will also switch your output device to <R> Hz while recording. Other apps will hear the device at that rate." The device's prior nominal rate is saved at lane start and restored best-effort at session finalization (restore failure is logged, never fatal).
- If setting R fails (the device does not support R): fail the lane in PREPARING with the OSStatus surfaced and the message "Device does not support <R> Hz". Never silently fall back to the device's current rate while the manifest would claim R.
- Ground truth for the IOProc bytes is the aggregate input stream's virtual format (`kAudioStreamPropertyVirtualFormat`): read it back after the rate set and assert it is Float32 at R; on assertion failure, fail the lane. This virtual format replaces the tap format as the ASBD/ring-sizing ground truth (the exceptions are stated in Sections 7.2 and 6.2).
- **Rate-change notifications are never ignored, even in forced-rate mode.** On every `kAudioDevicePropertyNominalSampleRate` notification (on the physical device or the aggregate), re-read the effective IOProc format (the aggregate input stream's virtual format). If any field differs from the format the current segment was opened with → full lane rebuild (re-asserting R) + segment rotation + `rateChange` event, exactly as in Section 7.3. A segment must never contain mixed rates (Section 7.3); a user or another app changing the physical device's rate mid-recording therefore rotates the segment even though the target rate is pinned. Device *switches* still rebuild per Sections 7.4/7.5.
- Segments record the effective rate actually in force at segment open (normally R for every segment); the master remains Float32 CAF as always (Section 6).
- The CLI does not expose forced rate in v1 (no `--rate` flag; see Section 3's verb table) — it is a GUI-settings-only mode.

**Open Risks status (Section 11):** the entire mechanism above is unverified — whether a tap-backed private aggregate honors a nominal-rate override at all, whether the set propagates to the physical sub-device or returns an error, and whether the aggregate stream's virtual format then reports R. It must be validated hands-on before anything is built on it. If hands-on testing shows the override cannot work, or only works with side effects worse than described above, forced-rate mode is demoted to a documented v1 non-goal (the setting is removed from the UI — never shipped broken); nothing else in this design depends on it.

### 7.7 Summary of invariants

- Capture rate = tap-native rate = device nominal rate at lane start (unless forced-rate mode, which is loud about its costs — Section 7.6).
- The effective IOProc format always wins over expectations; nothing is ever hardcoded. Normally that is the tap format (`kAudioTapPropertyFormat`); in forced-rate mode only, it is the aggregate input stream's virtual format (`kAudioStreamPropertyVirtualFormat`) per Section 7.6.
- Any observed change in the effective IOProc format — from a rate change or a device change, in every mode including forced-rate — ⇒ full teardown/rebuild (Section 8 order) + segment rotation + manifest event. No partial restarts, no in-file rate mixing, no SRC inside System Audio Recorder's own code path, ever.

---

## 8. Error Handling & Recovery Design

This section is the safety-critical core of System Audio Recorder. It owns the canonical `ZeroWatchdog` specification (Bug-B all-zero dropout recovery), the canonical STRICT teardown order, the Bug-A level-attenuation response, the lane state machine, device-switch and sample-rate-change handling, ring-overrun and disk-space policy, and startup crash recovery. Sections 4, 5, 6, and 7 reference this section rather than restating it.

### 8.1 ZeroWatchdog — full specification (Bug B)

**The failure it targets.** After some uptime, the IOProc keeps firing on schedule with valid timestamps, but every sample is exactly `0.0f` even though the system is audibly playing sound — indistinguishable from legitimate digital silence by sample inspection alone (a paused player also delivers exact zeros). Every `CaptureLane` owns one `ZeroWatchdog` instance.

**Where it runs.** Zero-run accounting and all state transitions execute on the lane's `DrainLoop` thread, once per 50 ms drain cycle, using the zero-scan result already computed there (vDSP max-magnitude of the drained chunk `== 0.0` exactly; `-0.0` counts as zero — see Section 5). Corroboration data is produced by `ProcessCatalog` at 1 Hz — active in every watchdog state other than `NORMAL`, see "The corroboration signal" below — and published to an atomic snapshot, stamped with its poll time, that the drain thread reads. The rebuild itself is posted to the engine queue, because all `AudioHardware*` lifecycle calls are serialized there (Section 4).

**Zero-run counter.** `zeroRunSeconds` = consecutive all-zero duration, computed as accumulated all-zero frames ÷ sample rate. ANY nonzero sample on any channel resets `zeroRunSeconds` to 0 and returns the watchdog to `NORMAL` — this rule applies from every state, including `ESCALATED` (which also clears the escalation notification).

**States and transitions.**

| From | To | Condition |
|---|---|---|
| NORMAL | SUSPICIOUS | `zeroRunSeconds` ≥ **5 s** |
| SUSPICIOUS | CONFIRMED_DROPOUT | `zeroRunSeconds` ≥ **10 s** AND corroboration reports "audio expected" on ≥ **3 consecutive polls** |
| SUSPICIOUS | CONFIRMED_DROPOUT (uncorroborated fallback) | ≥ 3 consecutive corroboration reads errored (OSStatus) or stale AND `zeroRunSeconds` ≥ **60 s** |
| SUSPICIOUS | SUSPICIOUS (hold) | corroboration says "no one is playing" — hold indefinitely; genuine silence NEVER triggers a rebuild |
| CONFIRMED_DROPOUT | REBUILDING | immediately; drain thread posts a rebuild request to the engine queue (lane enters REBUILDING, see 8.4) |
| REBUILDING | POST_REBUILD_VERIFY | full teardown + recreation completed (order in 8.2, recipe in Section 4) |
| POST_REBUILD_VERIFY | NORMAL | any nonzero sample arrives |
| POST_REBUILD_VERIFY | SUSPICIOUS | still all-zero but corroboration now says "no one is playing" (indistinguishable from genuine silence) |
| POST_REBUILD_VERIFY | REBUILDING (next attempt) | corroborated zeros persist ≥ **10 s** after the rebuild |
| POST_REBUILD_VERIFY | REBUILDING (next attempt, uncorroborated fallback) | ≥ 3 consecutive corroboration reads errored (OSStatus) or stale AND zeros persist ≥ **60 s** since the rebuild completed — consumes an attempt from the budget, so `ESCALATED` stays reachable even when corroboration is unavailable |
| REBUILDING/POST_REBUILD_VERIFY | ESCALATED | **3** failed attempts within a sliding **10-minute** window |
| ESCALATED | REBUILDING | 60 s retry timer fires AND fresh snapshot says "audio expected" — OR the snapshot is stale/errored at timer fire (rebuild anyway; see "The escalated retry decision" below) |
| ESCALATED | SUSPICIOUS | 60 s retry timer fires AND fresh snapshot says "no one is playing" — zeros are now indistinguishable from genuine silence; the escalation notification is withdrawn |
| ESCALATED | NORMAL | any nonzero sample |

**Backoff and attempt budget.** Delay before rebuild attempt N within one dropout episode: attempt 1 → **0.5 s**, attempt 2 → **2 s**, attempt 3 → **5 s**. Hard cap: **3 attempts per 10-minute sliding window** (window tracked by attempt wall-clock timestamps). A "failed attempt" is either (a) a rebuild that completed but failed `POST_REBUILD_VERIFY`, or (b) a recreation step that returned a non-`noErr` OSStatus — in case (b) the engine tears down whatever was partially created (8.2 order) before the next attempt. Both kinds consume the budget (8.4 gives the separate failure policy for non-watchdog rebuilds). Exhausting the cap enters `ESCALATED`: post a UserNotifications alert with the copy "Capture appears broken; System Audio Recorder keeps retrying", keep the lane capturing (if the last recreation succeeded, the IOProc continues delivering zeros; the writer stays open in every case), set the menu-bar health chip to ⚠, and arm a retry timer that fires every **60 s**.

**The escalated retry decision.** At each 60 s timer fire, the watchdog reads the corroboration snapshot (freshness rule below) and takes exactly one of three actions:
1. Fresh snapshot says "audio expected" → `REBUILDING` (one full rebuild attempt).
2. Fresh snapshot says "no one is playing" → `SUSPICIOUS`, and the escalation notification is withdrawn — the zeros are now indistinguishable from genuine silence. If corroboration later re-confirms while zeros persist, the normal SUSPICIOUS → CONFIRMED_DROPOUT path re-engages.
3. Snapshot stale, or corroboration reads erroring → `REBUILDING` anyway (uncorroborated insurance — same rationale as the uncorroborated fallback rows; see the cost analysis below).
Escalated retries bypass the 0.5/2/5 s backoff schedule — the 60 s cadence is itself the throttle — but each one still counts as an attempt in the sliding 10-minute window, so a failed escalated attempt normally returns straight to `ESCALATED` via the 3-failed-attempts row and re-arms the timer; if the window has aged below 3 attempts, the normal backoff path resumes instead. This loop continues until nonzero audio returns or the user stops the session.

**The corroboration signal.** While any lane's watchdog is in ANY state other than `NORMAL` — i.e. `SUSPICIOUS`, `CONFIRMED_DROPOUT`, `REBUILDING`, `POST_REBUILD_VERIFY`, or `ESCALATED` — `ProcessCatalog` polls at 1 Hz answering "is any relevant process currently outputting audio?" via `kAudioProcessPropertyIsRunningOutput` on each process object from `kAudioHardwarePropertyProcessObjectList`. Polling must cover the entire dropout episode — not just `SUSPICIOUS` — because the state table above consumes LIVE corroboration outside `SUSPICIOUS`: the `POST_REBUILD_VERIFY` exits ("no one is playing" → `SUSPICIOUS`; "corroborated zeros ≥ 10 s" → next attempt) and each `ESCALATED` retry decision all depend on it. Polling stops only when the watchdog returns to `NORMAL`. This same trigger condition — watchdog in any non-`NORMAL` state — appears in `ProcessCatalog`'s trigger list (see Section 4).
Check all processes EXCLUDING System Audio Recorder's own PID and any processes matching the lane's `excludeBundleIDs` (excluded apps are not captured, so their output must not corroborate a dropout). A poll is "corroborated" when at least one relevant process reports `IsRunningOutput = true`. The confirm condition requires the latest 3 polls all corroborated.

**Snapshot freshness rule.** Every published snapshot carries its poll timestamp. A snapshot older than **3 s** is STALE and is treated as unavailable: it never counts as corroborated, and it never counts as evidence that "no one is playing" either. Every watchdog decision that reads corroboration — the SUSPICIOUS confirm, the corroborated `POST_REBUILD_VERIFY` exits, and each `ESCALATED` retry decision — uses only fresh (≤ 3 s old) snapshots. If the snapshot stays stale while the watchdog is outside `NORMAL`, each additional full second of staleness counts as one errored corroboration read toward the "≥ 3 consecutive corroboration reads errored or stale" condition of the two uncorroborated fallback rows (SUSPICIOUS → CONFIRMED_DROPOUT at zero-run ≥ 60 s, and POST_REBUILD_VERIFY → next REBUILDING attempt at ≥ 60 s since the rebuild). In `ESCALATED`, a stale or errored snapshot at timer fire selects action 3 of the escalated retry decision (rebuild anyway). No state can therefore hang waiting for corroboration that never arrives.

**Why exact-0.0 detection + corroboration cannot false-trigger on genuine silence.** Both tests must pass, and they fail in opposite directions. (1) Real program material essentially never produces sustained exact-`0.0f` on every channel — decoded/dithered content carries LSB-level noise — so 10 s of exact zeros already means "no signal is being mixed in." (2) Genuine silence (paused player, idle system) means no process reports `IsRunningOutput = true`, so corroboration fails and the watchdog holds in `SUSPICIOUS` forever — a 2-hour lull never rebuilds (a mandatory test, Section 10). The only theoretical false-positive is a process claiming `IsRunningOutput = true` while rendering exact digital zeros for 10+ s (e.g. playing a silent file); the cost analysis below shows that rebuild is harmless.

**Cost analysis of a false rebuild.** Teardown + recreation completes well under 1 s; with the 0.5 s first-attempt backoff the total capture gap is < 1 s. Because the trigger condition guarantees the signal was exactly zero *up to the moment of teardown*, the "lost" audio is almost certainly silence: under `preserveWallClock` the writer's silence fill makes the master byte-equivalent to uninterrupted capture provided the source remained silent through the gap (highly likely given the exact-zero trigger, though not guaranteed — the worst case is < 1 s of real audio lost if playback resumed at exactly the wrong moment); under `compressTimeline` at most ~1 s is elided and noted in the manifest. A false rebuild costs effectively nothing, while a missed real dropout costs minutes of dead recording — this asymmetry is why the uncorroborated 60 s fallback rebuilds rather than waits: < 1 s of gap during what is already silence is cheap insurance.

**File continuity and timeline policy.** The `SegmentWriter` and the current CAF segment stay OPEN across rebuilds — no segment rotation for Bug-B recovery. The per-session timeline policy (user setting, Settings → Recording) is:
- `preserveWallClock` (default): after the rebuild, the writer inserts exactly the wall-clock gap worth of silence frames, computed from the host-time delta between the last frame drained before teardown and the first frame delivered after recreation (host-time delta → seconds → frames at the segment's sample rate). Segment duration remains wall-clock-accurate.
- `compressTimeline`: no fill; the gap exists only as a manifest event.

**Manifest logging.** Every rebuild episode appends to the lane's `events[]`: `{type: zeroDropoutRebuild, atWallTime, framePosition, gapMs, details: {attempts}}` (canonical schema in Section 6.4). `framePosition` is the segment-relative frame index where the gap begins; `details.attempts` is the count used in that episode.

**Configurability and caveat.** All watchdog thresholds (5 s arm, 10 s confirm, 3-poll corroboration, 3 s snapshot freshness, 60 s uncorroborated fallback — one value shared by both fallback rows, 0.5/2/5 s backoff, 3 attempts/10 min, 60 s escalated retry) live in a single Advanced settings group with the defaults above. The implementer must re-verify Bug B exists on their macOS build; keep the watchdog regardless — it is harmless when the bug is absent (it simply never leaves NORMAL/SUSPICIOUS).

### 8.2 STRICT teardown order (canonical)

Any teardown — watchdog recovery, device switch, sample-rate change, entry into `WAITING_FOR_DEVICE`, or normal stop — uses this exact order, executed on the engine queue (a device's later return from `WAITING_FOR_DEVICE` triggers only the *recreation* half, because this teardown already ran on entry — see 8.5):

1. `AudioDeviceStop(aggID, procID)`
2. `AudioDeviceDestroyIOProcID(aggID, procID)`
3. `AudioHardwareDestroyAggregateDevice(aggID)`
4. `AudioHardwareDestroyProcessTap(tapID)`

Then, for a rebuild, FULL recreation from scratch per the creation recipe in Section 4 (resolve device → CATapDescription → create tap → read tap UID/format → aggregate dictionary → create aggregate → set buffer frame size to the calibrated value → create IOProc → start). **Partial restarts are known-ineffective for Bug B**: restarting only the IOProc, or recreating only the aggregate device while reusing the tap, does NOT reliably clear the all-zero state. The only confirmed fix is the full teardown and rebuild above. `TapFactory` owns both the recipe and this order; no other module may call the destroy functions.

Teardown error handling: if any step returns a non-`noErr` OSStatus (e.g. the device already died), log the status via `os.Logger` and CONTINUE with the remaining steps — a failed destroy must never abort the teardown or leak the later objects. Sequencing with the drain thread: after step 1 returns, the producer is silent; the engine queue signals the `DrainLoop`, waits for one final drain pass to empty the ring, then proceeds with steps 2–4. If the rebuild changes sample rate or channel count, the ring buffer is reallocated during recreation (producer is stopped, so this is safe).

### 8.3 Bug A — level-attenuation response

Captured level can scale down with the number of stereo output pairs the target device exposes (~12 dB observed on a 4-pair interface; ~0 dB on true 2-channel devices). Three layers, fidelity-first:

1. **Heuristic warning.** Whenever the target output device exposes > 2 output channels, show a persistent badge/warning in the menu-bar UI and `systemaudiorecorder devices` output: "This device exposes N output channels; a known macOS bug may attenuate captured level — roughly 20·log₁₀(number of stereo pairs) dB, about 12 dB on a 4-pair interface. Run Calibration or choose a 2-channel device for exact levels." (The scaling law: level scales roughly as 20·log₁₀ of the output stereo-pair count, i.e. ~6 dB per *doubling* of pairs, consistent with the ~12 dB measured at 4 pairs.) Re-evaluated on every device switch (8.5).
2. **Calibration (user-invoked, `CalibrationService`).** Explicit consent dialog first: "System Audio Recorder will play a 5-second test tone through <device>." Then play a **997 Hz sine at −20 dBFS for 5 s** through the target device while capturing through a temporary lane; measure captured RMS over the **middle 3 s** (discarding the first and last second skips ramp/settling); `gainCompensationDB = −20 − capturedRMSdB`. Store the profile keyed by `(deviceUID, outputChannelCount, macOSBuild)`; any key component changing invalidates it. Profiles live in a JSON file at `~/Library/Application Support/System Audio Recorder/calibration.json`, read and written by both the GUI and the CLI (separate processes, no IPC) and always written atomically via a temp file + rename so a concurrent reader never sees a partial write. Per-profile schema: `{deviceUID, outputChannelCount, macOSBuild, gainCompensationDB, measuredAt, referenceVolume}` — `referenceVolume` is nullable (see R1). The session manifest snapshots the profile in use at record time, so later recalibration never silently changes an existing session's interpretation. Open-Risks note (Section 11): whether the tap level is pre- or post-hardware-volume must be verified hands-on; if pre-volume, calibration can run at low device volume without loud playback.
3. **Compensation policy.** The MASTER file is ALWAYS written raw/untouched — no gain on the capture path, ever. `gainCompensationDB` is stored in the session manifest (`lanes[].calibration`). Live meters display compensated values with a small "cal" badge. `ExportService` offers "Apply level compensation" (a single float scalar multiply), default **ON** when a profile exists, stated in the export UI. The Advanced setting "Bake compensation into master" defaults **OFF**, with a warning that it modifies samples.

### 8.4 Lane state machine

Canonical states and transitions for `CaptureLane` (all transitions executed on the engine queue):

```
IDLE → PREPARING → RUNNING ⇄ REBUILDING
RUNNING → WAITING_FOR_DEVICE → (PREPARING | FINALIZING)
RUNNING → STOPPING → FINALIZING → IDLE
any state → FAILED(reason)
```

- **PREPARING**: resolve device + rate → create tap → aggregate → IOProc → start (Section 4 recipe). On ANY OSStatus error: retry the whole sequence once after **250 ms** (tearing down whatever was partially created, in 8.2 order); if the retry also fails → `FAILED` with the OSStatus surfaced to the UI/CLI (CLI exit code 4).
- **RUNNING**: normal capture; ZeroWatchdog active; DeviceObserver listeners armed.
- **REBUILDING**: teardown + recreate (8.2); entered from watchdog CONFIRMED_DROPOUT, device switch, or rate change; returns to RUNNING on success. The failure policy depends on the trigger:
  - *Watchdog (Bug-B) rebuilds*: governed by the 8.1 attempt budget. A recreation-step OSStatus failure counts as one failed attempt consuming the budget — tear down whatever was partially created (8.2 order), then the next attempt follows the 0.5/2/5 s backoff; exhausting 3 attempts per 10-minute window → ESCALATED (8.1).
  - *Device-switch, rate-change, and device-return rebuilds (8.5)*: the watchdog attempt budget does NOT apply (the watchdog is typically in NORMAL). A recreation-step OSStatus failure follows the PREPARING policy: tear down partial objects in 8.2 order, retry the whole sequence once after **250 ms**, and if the retry also fails → FAILED with the OSStatus surfaced (CLI exit code 4).
- **WAITING_FOR_DEVICE**: fixed device vanished (8.5); goes to PREPARING if the device returns, FINALIZING on timeout.
- **STOPPING → FINALIZING**: per-lane work only — drain the ring fully, patch that lane's CAF sizes and frame counts, and update that lane's segment/manifest entries, then IDLE. Session-level finalization — writing the manifest `finalizedAt`, removing the `.recording.lock` file (created at session start, during PREPARING), and running the `onSessionFinalize` hook (Section 3) — happens EXACTLY once per session, executed by `CaptureEngine` on the engine queue after ALL lanes have finished finalizing; no individual lane performs these steps.
- **FAILED(reason)**: terminal for the lane; the session finalizes whatever was written; reason logged as an `error` manifest event and surfaced in UI/CLI.

### 8.5 Device switches, rate changes, and the missing device

**Device switch under `.followSystemDefault` — the AirPods case, end to end.** A user is recording the system mix through the MacBook's built-in speakers at 48 kHz. They open their AirPods case; macOS switches the default output device to the AirPods.
1. `DeviceObserver`'s listener on `kAudioHardwarePropertyDefaultOutputDevice` fires and dispatches onto the engine queue.
2. The lane transitions RUNNING → REBUILDING. `AudioDeviceStop` halts the old IOProc; the drain thread empties the ring's remaining built-in-speaker frames into the current segment.
3. `SegmentWriter` rotates: `segment-001.caf` is finalized (sizes patched); the manifest records its final frame count.
4. `TapFactory` completes the strict teardown (8.2) of the old tap + aggregate, which still referenced the built-in speakers' UID.
5. The engine resolves the new default device (AirPods): UID, `kAudioDevicePropertyNominalSampleRate` (may differ from 48 kHz), output channel count. Full recreation follows — new CATapDescription, tap, aggregate (AirPods UID as main sub-device), IOProc, start. The ring is reallocated if the format changed. If any recreation step errors, the non-watchdog failure policy in 8.4 applies (one 250 ms retry, then FAILED).
6. `segment-002.caf` opens at the AirPods' native rate; per-segment `sampleRate`, `startWallTime`, `startHostTime` go into the manifest; a `deviceSwitch` event is appended and `session.deviceHistory[]` gains the AirPods entry.
7. Bug-A logic re-evaluates: AirPods expose 2 output channels → the >2-channel warning clears; `CalibrationService` looks up a profile for the new `(deviceUID, outputChannelCount, macOSBuild)` — if none, meters run uncompensated and the calibration field is null for subsequent audio.
8. Health chip shows ⚠ Rebuilding for the sub-second switch, then ● Recording. The switch gap is represented by the segment boundary (per-segment start host times give exact alignment); no silence fill across rotations — `preserveWallClock` fill applies only to same-segment gaps (Bug-B rebuilds, overruns).

**Mid-capture sample-rate change.** If the tapped device's `kAudioDevicePropertyNominalSampleRate` changes (user action in Audio MIDI Setup, or another app claiming the device), `DeviceObserver` fires → full lane rebuild (8.2 teardown + recreation, so the tap format is re-read) + segment rotation at the new rate + `rateChange` event `{details: {fromRate, toRate}}`. Never resample to hide the change — segments at different rates coexist in one session (Section 6); the master path performs no SRC ever (Section 5).

**Fixed device disappears (`.fixed(deviceUID)`).** On device-death/list-change notification: lane → `WAITING_FOR_DEVICE`; the ring is drained and the current segment finalized; the full strict teardown (8.2) of the dead device's tap/aggregate/IOProc runs **immediately on entry** (the destroy calls tolerate non-`noErr`, since the device is already gone), so both possible exits start from a clean slate; a `waitingForDevice` event is logged; health chip shows ◌ Waiting for device. The session stays open up to `waitForDeviceTimeout` (default **5 min**, configurable). If the device returns (device-list-changed shows its UID), the lane re-enters PREPARING: full recreation, new segment, resume, `deviceSwitch` event. On timeout: finalize the session gracefully (FINALIZING) and post the notification "Recording stopped: <device> did not return within <timeout>."

### 8.6 Ring overrun policy and disk-space guard

**Overrun (producer side).** If the IOProc cannot fit an incoming chunk in the ring, it drops the ENTIRE chunk — never partial frames, so frame alignment is preserved — and increments the atomic `droppedChunks` and `droppedFrames` counters (Section 5). Nothing else happens on the real-time thread.

**Overrun (drain side).** Each 50 ms cycle the drain compares counters against its last-seen values; on a delta it writes an `overrunGap` event to the manifest — `{type: overrunGap, atWallTime, framePosition, gapMs, details: {framesLost, chunks}}` (canonical schema in Section 6.4) — with `details.framesLost` and `gapMs` computed from the `droppedFrames` counter delta and `details.chunks` from the `droppedChunks` delta. Under `preserveWallClock`, the drain inserts exactly `droppedFrames` of silence into the segment (the exact counter beats a wall-clock estimate); under `compressTimeline`, no fill.

**Persistent-overrun warning.** If ≥ **3** `overrunGap` events occur within **60 s**, raise the UI warning "Disk can't keep up — check free space / other I/O." The warning latches as a health-chip warning for the rest of the session and posts at most one notification per 10 minutes.

**Disk-space guard.** While any lane is recording, check free space on the volume containing the recordings root every **10 s** (via `volumeAvailableCapacityForImportantUsage`). Below **500 MB**: graceful stop — STOPPING → FINALIZING for all lanes (ring drained, CAF patched, manifest finalized) — plus a disk-space-stop notification. A graceful stop, not a crash: everything captured so far is fully playable.

### 8.7 Startup crash recovery

CAF masters are written with the unknown-size (`-1`) audio data chunk, so a crash mid-recording leaves a valid, readable-to-EOF file. The launch-time recovery scan — identifying candidates by missing/null `finalizedAt`, the 30 s recency guard (Section 6.5), truncating mid-frame-crashed segments to the last whole-frame boundary before patching, patching CAF data-chunk sizes and frame counts, setting `session.recovered = true` and stamping `finalizedAt`, and synthesizing a minimal manifest for orphaned segment folders — is owned canonically by **Section 6.5**; this section deliberately does not restate the procedure, and where any wording differs, Section 6.5 wins. From the error-handling perspective the guarantees are: recovery is idempotent, runs before the library index is served (users never see a corrupt-looking session), never touches a session another live System Audio Recorder process (GUI vs CLI — no IPC) is still writing, and surfaces every recovered session with the "Recovered" health badge (Section 3).

---

## 9. Permissions, Entitlements, and Distribution Plan

### 9.1 The permission key — both binaries

System-audio capture via the Process Tap API is gated by the TCC service **SystemAudioCaptureRequests**. The requesting binary MUST carry the Info.plist key **`NSAudioCaptureUsageDescription`**. This key does **not** appear in Xcode's Info.plist key dropdown — type the raw key name manually (add row and paste the literal string, or edit the plist source). Its value, identical in both binaries, is exactly:

> System Audio Recorder records the audio your Mac plays — system-wide or from apps you choose. macOS requires your permission for this.

- **GUI app** (`com.systemaudiorecorder.app`): key goes in the normal `System Audio Recorder.app/Contents/Info.plist`.
- **CLI** (`com.systemaudiorecorder.cli`): a bare Mach-O executable has no bundle, so the CLI embeds a complete Info.plist into its binary via the `__TEXT,__info_plist` linker section. Add to the `systemaudiorecorder` target's OTHER_LDFLAGS: `-Wl,-sectcreate,__TEXT,__info_plist,$(SRCROOT)/systemaudiorecorder/systemaudiorecorder-Info.plist`. That plist contains at minimum: `CFBundleIdentifier` = `com.systemaudiorecorder.cli`, `CFBundleName` = `systemaudiorecorder`, `CFBundleShortVersionString` and `CFBundleVersion` (lockstep with the app's), `LSMinimumSystemVersion` = `14.4`, and `NSAudioCaptureUsageDescription` with the exact string above. TCC reads the embedded plist exactly as it would a bundle's.

### 9.2 Why two separate TCC grants

TCC keys each grant to the *requesting* binary's stable code-signing identity plus bundle identifier. The app and CLI are different executables with different bundle ids, and per Section 4 they do not talk to each other (no XPC/IPC in v1) — neither can borrow the other's grant. A user of both surfaces therefore sees **two** system prompts and **two** rows in System Settings. This is the accepted v1 trade-off: it keeps the CLI fully headless and standalone. The embedded Info.plist is what attaches the CLI's grant to `com.systemaudiorecorder.cli` itself rather than to the invoking terminal. Background fact to respect from day one: ad-hoc or unsigned builds may never reliably trigger or retain the permission, so even development builds must be signed with a stable certificate (Developer ID, or at least Apple Development).

### 9.3 User-visible TCC flow, step by step

1. **First run**: onboarding sheet (Section 3) explains what will happen, with one button: **"Enable System Audio Capture."**
2. Pressing it calls `PermissionBroker.requestCapturePermission()` (below), which attempts a minimal throwaway tap. Because no grant exists yet, macOS presents a modal prompt, approximately: *"System Audio Recorder" would like to record this computer's audio*, with our §9.1 usage string as the explanation and **Allow** / **Don't Allow** buttons. The chrome is OS-controlled; only the description string is ours.
3. **Allow** → probe tap creation succeeds; the grant is recorded under **System Settings → Privacy & Security → Screen & System Audio Recording** as a row named "System Audio Recorder" (the CLI gets its own row, "systemaudiorecorder," after its first request). Sub-grouping inside that pane varies by macOS release — cosmetic only.
4. **Don't Allow** → the probe fails with a nonzero OSStatus. macOS shows the prompt **once**; later tap-creation attempts fail silently with no new prompt. The user must flip the toggle in System Settings manually.
5. **Denial UX**: on probe failure the sheet swaps to a denial state: text naming the exact pane, plus an "Open System Settings" button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`. The anchor is unverified (Risk R4, Section 11); if it fails testing, use the anchor-less `x-apple.systempreferences:com.apple.preference.security` and rely on the pane name in the text. When the app becomes active again, PermissionBroker re-probes automatically.
6. **Revocation while running**: running taps die or go silent; the lane surfaces this via the normal failure/watchdog paths (Section 8). The next start attempt re-probes and shows the denial state.
7. **CLI flow**: `systemaudiorecorder record …` runs the same probe first. If it cannot be granted (denied, or no GUI session — e.g. SSH), exit with code **2** (permission denied) and print the pane name to stderr.

### 9.4 PermissionBroker probe design

Public API cannot query TCC state for this service, so `PermissionBroker` **infers** state, with two implementations selected at build time.

**Default: public throwaway-tap probe.**
- Build a minimal `CATapDescription`: global stereo-mixdown tap excluding System Audio Recorder's own PID, `isPrivate = true`, muteBehavior unmuted.
- Call `AudioHardwareCreateProcessTap` **on the engine queue, never the main thread** — when the prompt is up, the call can block until the user answers.
- Result `noErr` + valid tap AudioObjectID → immediately `AudioHardwareDestroyProcessTap` → outcome **granted**. Any error → **notGranted** (the public API cannot distinguish "denied" from "never asked"; the first-ever probe *is* the ask).
- Cache the last outcome in `UserDefaults` key `permission.audioCapture.lastKnown` (values: `unknown`, `granted`, `notGranted`) so the UI renders state without probing on every launch. A failed probe after a cached `granted` means the user revoked → show the §9.3 denial state.
- The probe runs only (a) from the onboarding button, (b) before starting any session, (c) on app-became-active after opening System Settings. Never on a timer.

**Optional: `PRIVATE_TCC_PROBE` build flag (Swift compilation condition; default OFF).** For dev builds that want *exact* status without side effects — the private-SPI pattern, fully specified here:
- At runtime, `dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)`.
- `dlsym` the symbol `TCCAccessPreflight`: C function taking a `CFStringRef` service name and a `CFDictionaryRef` options (pass NULL), returning a C `int`.
- Call it with the service-name CFString `kTCCServiceSystemAudioCapture` (construct the CFString literally; the constant is not exported publicly).
- Interpret the return: **0 = granted, 1 = denied, 2 = not determined (never prompted)**. Mapping MUST be re-verified on the implementer's OS (Section 11, R11).
- If `dlopen`/`dlsym` fails or the value is out of range, silently fall back to the public probe. The flag ships **OFF** in all distributed builds — private SPI is a notarization and stability liability; it exists only to ease dev/test iteration (§9.5).

### 9.5 Developer/test reset

To re-exercise the prompt during development: `tccutil reset SystemAudioCaptureRequests com.systemaudiorecorder.app` (and `tccutil reset SystemAudioCaptureRequests com.systemaudiorecorder.cli` for the CLI). Used by the permission tests in Section 10.

### 9.6 Entitlements and hardened runtime

One shared entitlements plist, `SystemAudioRecorder.entitlements`, applied to **both** the app and the CLI at signing time:

| Key | Value | Why |
|---|---|---|
| `com.apple.security.device.audio-input` | `true` | Mic-class entitlement; likely required under hardened runtime for the capture grant to function. **VERIFY hands-on** (Section 11, R3) — drop it if capture works without it and it provokes a spurious Microphone prompt. |
| `com.apple.security.app-sandbox` | **absent** (never `true`) | Sandbox is OFF. Background fact: the Process Tap API is fragile/unreliable under the full App Sandbox; known reference implementations ship unsandboxed. |
| `com.apple.security.get-task-allow` | **absent in Release** | Xcode injects it in Debug signing; notarization rejects it. |

No other entitlements. **Hardened runtime is not an entitlement key** — it is enabled by signing with `--options runtime` (Xcode: "Hardened Runtime" capability ON for every target). System Audio Recorder needs no hardened-runtime exception entitlements (no JIT, no unsigned executable memory, no DYLD variables).

### 9.7 Signing, notarization, stapling pipeline

Packaging decision: the CLI ships **inside the app bundle** at `System Audio Recorder.app/Contents/Helpers/systemaudiorecorder`; Settings → Advanced offers "Install command-line tool," which symlinks it to `/usr/local/bin/systemaudiorecorder` (a symlink does not change code identity, so the TCC grant follows the real binary). Install mechanism: attempt the symlink directly; on `EACCES`/`ENOENT` (missing or root-owned `/usr/local/bin`), run `mkdir -p` + `ln -sf` via an osascript "do shell script … with administrator privileges" prompt; replace any existing symlink; surface failure inline in Settings with the manual one-liner as fallback copy. This yields a single notarized artifact. Pipeline (scripted as `Scripts/notarize.sh`; CI dry-runs it in Phase 0, see Section 12):

1. **One-time setup**: install the "Developer ID Application: \<Name\> (\<TEAMID\>)" certificate; store notary credentials once: `xcrun notarytool store-credentials SystemAudioRecorderNotary` (App Store Connect API key or Apple ID + app-specific password).
2. Build Release configuration of all targets.
3. **Sign inside-out, never `--deep`**: first the nested CLI — `codesign --force --timestamp --options runtime --entitlements SystemAudioRecorder.entitlements --sign "Developer ID Application: …" System Audio Recorder.app/Contents/Helpers/systemaudiorecorder` — then any other nested code, then the app bundle itself with the same flags. Note: `TapKit` is *statically linked* (Section 4.1), so there is no embedded framework to sign in v1; if the layout ever changes to an embedded `TapKit.framework`, sign it between the CLI and the outer app (frameworks get `--timestamp --options runtime` but **no** entitlements plist). Sparkle, if Phase 9 adds it, is nested code signed per its own documentation at this same step.
4. Local verify: `codesign --verify --strict --verbose=2 System Audio Recorder.app` and `codesign -d --entitlements - System Audio Recorder.app` (confirm exactly the §9.6 set, no `get-task-allow`).
5. Zip for submission: `ditto -c -k --keepParent System Audio Recorder.app System Audio Recorder.zip` (ditto preserves the metadata notarization requires).
6. `xcrun notarytool submit System Audio Recorder.zip --keychain-profile SystemAudioRecorderNotary --wait`. On "Invalid," run `xcrun notarytool log <submission-id> --keychain-profile SystemAudioRecorderNotary` and fix.
7. `xcrun stapler staple System Audio Recorder.app` (staple the .app — the zip cannot be stapled).
8. Build the distribution DMG from the stapled app (`hdiutil create`), `codesign --sign "Developer ID Application: …" System Audio Recorder.dmg`, submit the DMG through notarytool the same way, then `xcrun stapler staple System Audio Recorder.dmg`.
9. Gates: `stapler validate System Audio Recorder.app`, `stapler validate System Audio Recorder.dmg`, `spctl -a -vv -t install System Audio Recorder.dmg` must pass; then a clean-machine (or fresh-VM) Gatekeeper first-open test.

The standalone CLI needs no separate submission — it rides inside the notarized app bundle and its own signature was covered in step 3.

### 9.8 Why the Mac App Store is off the table

MAS mandates the App Sandbox with no opt-out, and it is an established fact (background) that the Process Tap API is fragile/unreliable under the full sandbox — the core capture feature cannot ship that way. Further frictions stack on top: user-chosen recording folders, the `/usr/local/bin` symlink, user shell hooks (Section 3), and optional Sparkle self-updates are all sandbox-hostile. Developer ID + notarization delivers a Gatekeeper-clean install without capping the product, so no design effort goes to a MAS variant. (System Audio Recorder is a working title; renaming touches only bundle ids, the usage string, and signing config.)

---

## 10. Testing & Validation Plan

Test framework: **XCTest** for all Swift/C unit tests (the `SystemAudioRecorderRT` C library is tested through a thin Swift wrapper target). CI (macOS 14.4+ runner) runs 10.1–10.2 on every commit. Everything from 10.3 onward needs live audio hardware and a TCC grant, so those are **manual/dedicated-Mac procedures**. Tooling split: the automated diagnostics ship as hidden `systemaudiorecorder diag` subcommands — asset generation (`gen-null-asset`, 10.3), `filecheck` (10.2), and `nulltest` (10.3) — so they run without Xcode; the Bug-B soak (10.5) is a shell script (`scripts/soak.sh`) driving the normal CLI, and the permission flow (10.6) and crash-kill recovery (10.7) are manual checklist/harness procedures.

### 10.1 Unit tests

#### 10.1.1 Ring buffer fuzz (`td_ring_t`)

Goal: prove the SPSC ring (see §5) delivers a byte-exact stream across wrap boundaries under concurrent load, with exact overflow accounting.

- **Deterministic wrap tests (single-threaded):** capacity 4096 bytes; chunk sizes landing exactly on, one byte before, and one byte after the wrap point; read bytes must equal written bytes.
- **Concurrent fuzz:** one producer thread, one consumer thread; capacity deliberately small (**64 KiB**) to force thousands of wraps. Producer writes frame-aligned chunks of random frame counts (1–2048 frames; frame = 8 bytes, stereo Float32); consumer reads random frame counts (1–4096) with random 0–2 ms sleeps. Payload is a deterministic xorshift64 byte stream so the consumer verifies every byte positionally with no reference copy. Run **8 fixed seeds (0–7)**, **10 million frames per seed**. Pass: (a) consumed stream matches the generator stream exactly, accounting for dropped chunks — concretely, the single-threaded producer logs each dropped chunk's absolute byte offset and length, and final verification replays the deterministic generator over the full stream, skipping the logged dropped ranges, and compares against the consumed bytes; (b) `framesAccepted == framesRead + framesInRingAtEnd`; (c) `droppedChunks`/`droppedFrames` match the producer's local drop log.
- **Overflow policy:** suspend the consumer, write until rejection; assert drop-**all-or-nothing** (no partial frame ever readable; counters correct after resume).
- **Memory order:** the concurrent fuzz also runs under Thread Sanitizer in CI; any race report fails.

#### 10.1.2 Watchdog state-machine simulation

`ZeroWatchdog`'s decision logic must be a pure function of (virtual clock, zero-run duration, corroboration result stream) with the rebuild executor injected as a closure, so tests drive simulated time and count rebuild invocations. Scripted scenarios (thresholds are the canonical §8 numbers):

1. Zeros for 5 s → state `SUSPICIOUS`; a single nonzero sample on any channel → back to `NORMAL`, zero-run reset to 0.
2. Zeros ≥ 10 s AND corroboration reports "audio expected" for 3 consecutive 1 Hz polls → `CONFIRMED_DROPOUT` → exactly one rebuild invocation.
3. **Genuine-silence-forever (the critical no-rebuild case):** zeros for a simulated **6 hours** with corroboration always reporting "no non-System Audio Recorder process outputting audio." Assert: state remains `SUSPICIOUS` for the whole run, rebuild executor invoked **0 times**, no `zeroDropoutRebuild` manifest event emitted.
4. Corroboration reads throw errors → uncorroborated fallback rebuild fires at zero-run ≥ 60 s, not before.
5. Rebuild verify-failure loop: post-rebuild corroborated zeros persist ≥ 10 s → next attempt. Assert the simulated delay before each attempt matches §8's per-episode schedule exactly: **0.5 s before attempt 1, 2 s before attempt 2, 5 s before attempt 3**. Hard cap **3 attempts per 10-minute window**: the **3rd failed attempt** inside the window → `ESCALATED` (never a 4th backoff attempt); in `ESCALATED`, retries occur every 60 s (the 60 s cadence replaces the 0.5/2/5 s schedule, §8) and exactly one user notification is posted.
6. Nonzero arriving mid-`POST_REBUILD_VERIFY` → `NORMAL`. Attempt bookkeeping per §8: the per-episode backoff numbering resets (a later episode's first attempt gets the 0.5 s delay again), but consumed attempts keep their wall-clock timestamps in the sliding 10-minute window. Assert both halves: (a) after 2 failed attempts, nonzero → `NORMAL`, and a new dropout episode 1 simulated minute later rebuilds with a 0.5 s backoff; (b) when that new episode's first attempt also fails verify, the watchdog enters `ESCALATED` — the window now holds 3 failed attempts; (c) the same sequence re-run with the second episode starting 11 simulated minutes later does NOT escalate on its first failure (the earlier attempts aged out of the window).

#### 10.1.3 Manifest round-trip

Construct an in-memory session exercising every field of the `session.json` v1 schema (§6): multi-lane, all six event types, a calibration profile, `deviceHistory`, both `finalized` states. Encode → decode → assert structural equality. Also: unknown extra keys are ignored (forward compatibility); missing `finalizedAt` decodes as "needs recovery"; `schemaVersion` > 1 is rejected with a typed error.

#### 10.1.4 Naming templates

Test the session-folder template expander (§6) with all tokens `{date} {time} {source} {app} {device} {rate}`: default-template expansion; filesystem-illegal characters (`/`, `:`, NUL) in app/device names replaced with `-`; result capped at 200 bytes UTF-8; collisions append `" (2)"`, `" (3)"`, …; empty tokens (no app in a system-mix session) collapse without doubled separators.

### 10.2 File-layer bit-exact self-test

Guards against the float→Int32 WAV-class truncation bug ever reappearing in the master path (§6). Runs automatically at every app and CLI launch in **all builds** (not debug-only); on any mismatch, System Audio Recorder refuses to record until the check passes. The hidden diagnostic `systemaudiorecorder diag filecheck` is the manual entry point for the same check (§6.2 is canonical for this behavior).

Procedure: generate exactly 1 s of stereo Float32 at 48 kHz whose sample values are raw LCG bit patterns (seed 0x54415044) reinterpreted as Float32, NaN patterns skipped — deliberately including denormals, −0.0, and magnitudes > 1.0. Write through `SegmentWriter` (identical client/file ASBDs, §6) to a temp CAF; read back with ExtAudioFile using the same ASBD; `memcmp` the raw byte buffers. Pass: byte-identical, read-back frame count exactly 48,000. Any difference is a hard failure.

### 10.3 Null-test methodology (fidelity validation — canonical procedure)

This is the ground-truth fidelity check. **Playback MAY use AVFoundation (AVAudioPlayer); the capture path NEVER does** — capture is always the raw IOProc path (§4, §5). The procedure is automated as `systemaudiorecorder diag nulltest [--device <uid>]`; the steps below are its specification.

**Test asset composition** — one continuous 60 s Float32 stereo interleaved CAF, identical signal on both channels, generated at the **target device's current nominal sample rate** at test time (never a fixed shipped rate — a rate mismatch triggers OS resampling and invalidates the test, §7). Segments are sample-accurate, butt-joined, no crossfades:

| # | t (s) | Content | Level |
|---|-------|---------|-------|
| 1 | 0–10 | 997 Hz sine | −6 dBFS peak (amplitude 0.5011872) |
| 2 | 10–20 | 200 Hz square | −6 dBFS (±0.5011872) |
| 3 | 20–40 | 20 Hz → 20 kHz log sweep | −6 dBFS peak |
| 4 | 40–45 | digital silence | exact 0.0f |
| 5 | 45–60 | pink noise, fixed seed 0x54415044 | −20 dBFS RMS |

**Numbered procedure:**

1. Pick a true **2-channel** output device (built-in speakers or headphone out) — this excludes Bug A from the measurement. Record device UID, channel count, nominal rate, macOS build.
2. Set it as system default output at 100% volume (removes the unresolved pre-/post-volume question, §11, as a variable). Warn the operator it will be audible; headphones recommended.
3. Generate the asset at the device's current rate: `systemaudiorecorder diag gen-null-asset --out nulltest-source.caf`.
4. Start capture via the normal TapKit path: system-mix source, default device, default settings (stereo mixdown, unmuted).
5. Wait 2 s (lead-in), then play `nulltest-source.caf` once via **AVAudioPlayer**.
6. After playback ends, wait 2 s (tail); stop and finalize the session.
7. Load source and capture as Float32 arrays; verify the captured ASBD is Float32 at the device rate (else abort — the pipeline itself is broken).
8. **Time alignment:** cross-correlate the first 1.0 s of the source sine against the capture over a ±3 s window (vDSP); the lag at maximum correlation is the offset. Integer-sample alignment is acceptable for v1 (sub-sample optional).
9. Slice the capture to source length at that offset; compare channels independently (L→L, R→R).
10. Compute residual = source − capture, per channel.
11. Per segment, trim a **250 ms guard** at both boundaries (keeps OS-filter transition ringing out of neighboring segments), then compute residual RMS (dBFS) and peak.
12. Assert the silence segment's captured **interior is exactly zero** — every sample bit-equal to ±0.0, not merely low RMS.
13. Evaluate against the expectations table below.
14. **Baseline & regression:** on first run for a given (machine, deviceUID, macOS build), write all per-segment residuals to `~/Library/Application Support/System Audio Recorder/diagnostics/nulltest-baseline.json`. Later runs flag any segment residual RMS deviating more than **±1.5 dB** from baseline as a regression (nonzero exit, red report line).

**Expected residuals (research baseline — these are OS facts, not tunables):**

| Segment | Expected residual RMS | Verdict rule |
|---|---|---|
| 997 Hz sine | **≤ −70 dBFS** | Hard pass/fail gate |
| 200 Hz square | **≈ −3 dBFS** (research measured −2.9 dBFS; capture peak reads ~+2 dB high) | **EXPECTED — this is Apple's non-optional ingestion reconstruction filter (Gibbs ringing). It is NOT a System Audio Recorder defect; do not attempt to "fix" it.** Gate only via baseline ±1.5 dB |
| Log sweep | No absolute gate; record to baseline (HF end shows filter deviation) | Baseline ±1.5 dB |
| Silence | **Exactly zero** | Hard gate (step 12) |
| Pink noise | No absolute gate; record to baseline | Baseline ±1.5 dB |

Diagnosis order if the sine gate fails: (1) alignment offset wrong — inspect correlation peak; (2) level offset — you are on a >2-channel device (Bug A); (3) rate mismatch — asset generated at wrong rate, OS resampled.

### 10.4 Bug-A multichannel test

On a Mac with a >2-output-channel device (hardware interface, or a stand-in multi-output aggregate built in Audio MIDI Setup — note in the report that a stand-in may not reproduce the bug): (1) run the full 10.3 null test against it; if Bug A is live, expect a uniform level offset — level scales roughly as 20·log₁₀(number of output stereo pairs) dB, i.e. ~6 dB per doubling; the concrete expectation is ~12 dB at 4 pairs (research-measured); (2) verify the §8 heuristic badge appears for any device reporting > 2 output channels; (3) run `CalibrationService` and assert `gainCompensationDB` matches the null-test-measured offset within **±0.5 dB**; (4) bit-compare masters recorded with and without a calibration profile — identical (master is never gain-touched, §8); (5) export with "Apply level compensation" ON; exported RMS restored within ±0.5 dB. On a 2-channel device, calibration must return |gainCompensationDB| ≤ 0.5 dB.

### 10.5 Bug-B 24-hour soak

Run `systemaudiorecorder record --system` for 24 h on a dedicated Mac, driven by `scripts/soak.sh`: repeating cycle of 25 min pink-noise playback (`afplay` loop) + 5 min silence, **except a scripted 2-hour genuine-silence window at hours 12–14 with zero playback**. Assertions from the finalized manifest and logs: (a) **zero `zeroDropoutRebuild` events inside the 2 h silence window** — any rebuild there is a watchdog false positive and a release blocker; (b) if the dropout bug fires during playback windows, every rebuild recovers within **15 s** (`gapMs ≤ 15000`) with a well-formed manifest event; (c) never firing is also a pass (bug absent on this build — keep the watchdog regardless, §8); (d) no `overrunGap` events; (e) process RSS growth < 10% between hour 1 and hour 24; (f) the session finalizes cleanly and every segment reads to its stated frame count.

### 10.6 Permission-flow tests (manual checklist)

1. `tccutil reset SystemAudioCaptureRequests com.systemaudiorecorder.app` → launch → onboarding sheet → "Enable System Audio Capture" → system prompt attributed to System Audio Recorder → grant → a 5 s recording succeeds.
2. Reset again → **deny** → app shows the denial state; its button opens System Settings → Privacy & Security → Screen & System Audio Recording (verify the §9 deep-link anchor lands; log if not — open risk).
3. Grant manually in System Settings → return to app → probe succeeds without relaunch.
4. CLI separately (own grant, §1/§9): `tccutil reset SystemAudioCaptureRequests com.systemaudiorecorder.cli` → `systemaudiorecorder record --system --duration 5` → prompt attributed to the CLI; denial exits with code **2**.
5. If built with `PRIVATE_TCC_PROBE`: the exact-status probe must agree with observed prompt behavior; the default-OFF build must not link the SPI (`nm` check in CI).

### 10.7 Large-file and crash-recovery tests

- **4 GB+ segment (CAF 64-bit sizes):** a test harness feeds `SegmentWriter` synthetic deterministic Float32 frames faster than real time until the segment file exceeds **4.5 GiB**, then finalizes. Assert: ExtAudioFile reopens it, reported frame count matches frames written, and 1 s slices at start/middle/end are bit-exact against the generator. Repeat without finalizing (simulated crash): the unfinalized `-1`-size CAF must still read to EOF and recover.
- **Crash-kill recovery:** start a real recording; after ≥ 60 s, `kill -9` the process. Relaunch. `SessionStore`'s launch scan must mark the session "Recovered", patch CAF sizes from file length, and compute duration (§6). Assert recovered audio is playable and ends within **2 s** of the kill timestamp (50 ms drain cadence plus writer buffering bounds the loss). Verify the Library shows the "recovered" badge (Phase 5+).

---

## 11. Open Risks & Unknowns

This register aggregates every "verify hands-on" flag from Sections 4–10. Each risk is retired only by running its verification on the actual target macOS build and recording date + build + outcome in the project README. Nothing here blocks Phases 0–2.

**R1 — Bug A (level attenuation) still present; pre- vs post-volume unknown.**
- *Risk*: captured level scales down on >2-output-channel devices — roughly 20·log₁₀(number of stereo pairs) dB, i.e. ~6 dB per *doubling* of pairs (research measured ~12 dB at 4 pairs); separately, unknown whether the tap signal is pre- or post-hardware-volume, which determines whether calibration can run quietly.
- *Why unresolved*: OS-version-dependent bug from prior research; needs the implementer's hardware/OS, and a >2-channel interface may not be on hand.
- *Verify*: Section 10's Bug-A test (null test on a >2-channel device). Volume question: run the Section 8 calibration (997 Hz sine, −20 dBFS) at device volume 100% and 25%. Identical captured RMS ⇒ pre-volume (calibrate quietly); scaled ⇒ post-volume.
- *Fallback*: all three Section 8 response layers ship regardless. If post-volume: CalibrationService sets a fixed reference volume for the pass, restores it after, and records it in the profile.

**R2 — Bug B (all-zero dropout) still present; threshold tuning.**
- *Risk*: the intermittent all-zero IOProc output may or may not reproduce on the implementer's build; the 5 s / 10 s / 60 s watchdog thresholds (Section 8) come from research, not local measurement.
- *Why unresolved*: intermittent and uptime-dependent; may be altered by any macOS update.
- *Verify*: Section 10's 24 h soak with periodic playback, plus the scripted 2 h genuine-silence window (must produce zero false rebuilds).
- *Fallback*: keep ZeroWatchdog even if the bug seems absent — it is harmless when idle. All thresholds are in the Advanced settings group: raise the SUSPICIOUS threshold if false positives appear; lower confirmation times if recovery feels slow.

**R3 — `com.apple.security.device.audio-input` entitlement necessity.**
- *Risk*: unknown whether the mic entitlement is required under hardened runtime for the capture grant, merely harmless, or actively bad (could trigger a spurious Microphone TCC prompt).
- *Why unresolved*: the hardened-runtime ↔ SystemAudioCaptureRequests interaction is undocumented.
- *Verify*: Phase 0/1 — sign the spike CLI and app with and without the entitlement, `tccutil reset` between runs (Section 9), attempt the probe; note whether capture works and whether any Microphone prompt appears.
- *Fallback*: one-line entitlements change either way; prefer dropping it if capture works without it.

**R4 — System Settings deep-link anchor.**
- *Risk*: `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` may not land on the Screen & System Audio Recording pane.
- *Why unresolved*: pane anchors are undocumented and shift between macOS releases.
- *Verify*: `open` the URL on the target OS; confirm the destination pane.
- *Fallback*: open the anchor-less `x-apple.systempreferences:com.apple.preference.security` and rely on the pane name spelled out in the denial UI text (Section 9).

**R5 — `kAudioSubTapDriftCompensationKey: true` correctness.**
- *Risk*: drift compensation on the sub-tap could, in theory, engage resampling and break the no-SRC fidelity rule (Section 7), since the aggregate's only clock is the tapped device itself.
- *Why unresolved*: the key's semantics for this exact topology are undocumented.
- *Verify*: run the Section 10 null test twice — once with `true`, once with `false`. The 997 Hz residual (≤ −70 dBFS RMS) and the exactly-zero silence segment prove no SRC; keep whichever setting nulls better.
- *Fallback*: flip the single dictionary constant to `false` in TapFactory's recipe (Section 4).

**R6 — `matchDeviceLayout` (unmixed) channel behavior. RETIRED — feature removed.**
- `matchDeviceLayout` and the per-app (`.appSet`) capture mode it belonged to were removed entirely (Section 3.4): the only tap System Audio Recorder builds now is `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, whose channel behavior is already exercised by the Section 10.3 null test. Nothing in the shipped design depends on the unmixed per-process tap variant anymore.

**R7 — DRM capture works incidentally.**
- *Risk*: taps currently capture decoded PCM from FairPlay-protected sources (Apple Music, Netflix, Apple TV+); empirical, not an Apple guarantee, and could stop working in any release.
- *Why unresolved*: depends on Apple's protected-path implementation, outside our control.
- *Verify*: hands-on, private testing only — play a protected source during capture and inspect the result.
- *Legal/ToS note (binding)*: recording protected content may violate service terms or law regardless of feasibility. System Audio Recorder must never target, advertise, special-case, or attempt to circumvent DRM; no product copy mentions protected services. If the OS ever zeroes protected audio it will look like Bug B: corroborated zeros → up to 3 rebuilds → ESCALATED (Section 8). Acceptable — but the ESCALATED notification copy must not promise recovery.

**R8 — App Intents in an `LSUIElement` app.**
- *Risk*: Shortcuts discovery/execution of intents in menu-bar-only apps has historically been unreliable (intents missing until first launch, or requiring the app running).
- *Why unresolved*: discovery behavior varies by macOS release.
- *Verify*: Phase 8 — fresh install; check Start Recording / Stop Recording / Get Recording Status appear in Shortcuts before first launch, and that invoking them launches the app.
- *Fallback*: the `systemaudiorecorder://` URL scheme and CLI (Section 3) already cover automation; ship intents best-effort and document "open System Audio Recorder once after installing" if needed.

**R9 — Sparkle optionality.**
- *Risk*: Sparkle 2 is the only third-party dependency and only in Phase 9; under hardened runtime its embedded helpers must be signed/notarized correctly, enlarging the pipeline surface (Section 9).
- *Why unresolved*: integration cost and signing behavior can't be assessed until the notarization pipeline exists.
- *Verify*: Phase 9 — integrate, re-run the full §9.7 pipeline, exercise one real signed-appcast update cycle (EdDSA-signed).
- *Fallback*: ship v1 without auto-update; a "Check for Updates…" menu item opens the releases page. Nothing else depends on Sparkle.

**R10 — CLI TCC attribution and headless contexts.**
- *Risk*: the CLI's prompt must attribute to `com.systemaudiorecorder.cli` via its embedded Info.plist (not to Terminal); and no prompt can appear at all without a GUI session (SSH, launchd).
- *Why unresolved*: responsible-process attribution rules for this TCC service are undocumented.
- *Verify*: Phase 1 — on clean TCC state, run `systemaudiorecorder record` from Terminal; confirm the prompt names "systemaudiorecorder" and a separate Settings row appears. Repeat over SSH; expect failure.
- *Fallback*: for the headless case, exit code 2 with stderr instructions (Section 9); document that the first CLI grant must happen in a GUI session. For the misattribution case: if the grant attributes to the containing app, accept the single shared grant and simplify §9.2's two-grant description; if it attributes to the invoking terminal, document that the CLI must be launched directly (not through a shell wrapper that re-execs) and revisit the embedded-plist attribution with Apple's current rules.

**R11 — `PRIVATE_TCC_PROBE` SPI drift.**
- *Risk*: the private `TCCAccessPreflight` symbol and its 0/1/2 return mapping (Section 9) may change or vanish in any release.
- *Why unresolved*: private SPI carries no compatibility promise.
- *Verify*: dev builds assert `dlsym` success and in-range return values on the target OS.
- *Fallback*: already designed in — the flag ships OFF, and any runtime failure silently degrades to the public throwaway-tap probe.

**R12 — Forced-rate mode mechanism unverified.**
- *Risk*: Section 7.6's mechanism — setting `kAudioDevicePropertyNominalSampleRate` on the tap-backed private aggregate — may be refused, may not deliver tap buffers at the forced rate, or may propagate to the physical main sub-device and change the user's device rate: an additional disturbance the UI must disclose alongside the verbatim resampling warning.
- *Why unresolved*: the rate-override semantics of tap-backed private aggregates are undocumented.
- *Verify*: hands-on per Section 7.6 — set rate R on the aggregate, read back the tap/stream format, play content, and confirm buffer cadence and captured pitch/duration; also read the physical device's nominal rate before and after the set to detect propagation.
- *Fallback*: if the mechanism fails or has unacceptable side effects, demote Forced-rate mode to a v1 non-goal — Section 7.6 already frames it as default-off advanced, and removing it affects nothing else.

---

## 12. Phased Build Plan

Ordering principle: **the riskiest OS-dependent facts are proven first (Phase 1), and every phase ends with a runnable, testable artifact** — the CLI carries the product until Phase 5 so a working recorder exists long before any UI. Never start a phase until the previous phase's DONE-WHEN gate passes; gates reference the procedures in Section 10 by number.

### Phase 0 — Project skeleton & signing pipeline

Tasks:
- Create one Xcode project with the four targets from §2: `SystemAudioRecorderRT` (C static library), `TapKit` (framework), `SystemAudioRecorderApp` (app, bundle id `com.systemaudiorecorder.app`), `systemaudiorecorder` (CLI, bundle id `com.systemaudiorecorder.cli` via `__info_plist` linker section). Deployment target macOS 14.4.
- Type `NSAudioCaptureUsageDescription` manually into both Info.plists (exact string in §9 — the key is absent from Xcode's dropdown).
- Entitlements plist per §9.6 (audio-input entitlement; no sandbox key — see also Open Risks §11); enable Hardened Runtime as a signing option (`--options runtime` / the Xcode capability) on every target — it is not an entitlements-plist key.
- CI job: build both executables, `codesign` with the Developer ID identity + entitlements, `xcrun notarytool submit` a zipped stub app, `xcrun stapler staple` — the full pipeline on a do-nothing binary.
- Check in `scripts/soak.sh` stub and the XCTest targets (empty).

Deliverable: a signed, notarized stub app + CLI that launch and print a version string.

DONE WHEN: the notarized stub launches on a **clean second Mac** with no Gatekeeper warning; `codesign -d --entitlements -` shows the expected entitlements on both binaries; both Info.plists contain the usage string.

### Phase 1 — Spike: prove the capture stack end-to-end

Tasks:
- In the CLI only, hardcode the full §4 creation recipe: global tap (`CATapDescription`, excluding own PID) → `AudioHardwareCreateProcessTap` → private aggregate device (exact composition dictionary from §4) → `AudioDeviceCreateIOProcIDWithBlock` (NULL queue) → `AudioDeviceStart`.
- Read `kAudioTapPropertyFormat`; write 10 s straight to a CAF via ExtAudioFile with identical client/file ASBDs. (Spike may write from a plain callback-fed buffer; the real ring arrives in Phase 2.)
- Implement the strict teardown order (§8) on exit.
- Exercise the TCC prompt for `com.systemaudiorecorder.cli`.

Deliverable: `systemaudiorecorder` records 10 s of whatever the Mac is playing to `spike.caf`.

DONE WHEN: on a machine after `tccutil reset SystemAudioCaptureRequests com.systemaudiorecorder.cli`, running the spike triggers the system permission prompt; after granting, the produced CAF plays in QuickTime Player and audibly contains the source material; `afinfo` reports Float32 at the output device's current nominal rate. This gate de-risks the entire product — do not proceed past it with workarounds.

### Phase 2 — TapKit core: ring, lanes, writer

Tasks:
- Implement `td_ring_t` in `SystemAudioRecorderRT` per §5 (SPSC, C11 atomics, cache-line-separated indices, drop-all-or-nothing) + the real-time C capture context.
- Implement `TapFactory`, `IOProcHost`, `DrainLoop` (50 ms cycle, zero-scan, vDSP meters, interleave, synchronous write), `SegmentWriter` (CAF `-1` size chunk, finalize patch), the §8 lane state machine (`IDLE→PREPARING→RUNNING→STOPPING→FINALIZING`, `FAILED`), `CaptureEngine` with the engine queue, `SessionStore` manifest v1 write + launch recovery scan. SessionStore is built in Phase 2 — deliberately pulled forward from the spine's Phase 5 — because Phase 3's manifest events and Phase 2's crash-recovery gate depend on it.
- Read device nominal rate at lane start (§7); wire the CLI `record --system` verb onto TapKit.
- Implement the bit-exact self-test and `systemaudiorecorder diag filecheck` (10.2).

Deliverable: production-path CLI recorder producing session folders with `session.json`.

DONE WHEN: ring fuzz passes all 8 seeds + TSan (10.1.1); `diag filecheck` passes (10.2); manifest round-trip and naming-template suites pass (10.1.3–10.1.4); a 5-minute system recording finalizes with correct frame counts; the crash-kill test (10.7) recovers the session.

### Phase 3 — Resilience: ZeroWatchdog + DeviceObserver

Tasks:
- Implement `ZeroWatchdog` exactly per §8 (states, 5 s / 10 s / 3-poll / 60 s fallback thresholds, 0.5/2/5 s backoff, `ESCALATED`), with injected clock/corroboration for testability; rebuild = full teardown + recreate only.
- Implement `DeviceObserver` listeners; default-device switch, nominal-rate change → full rebuild + segment rotation; `WAITING_FOR_DEVICE` with the 5-minute timeout; timeline policies (`preserveWallClock` silence fill / `compressTimeline`); all §6 manifest events.
- Minimal `ProcessCatalog` (corroboration reads only, 1 Hz while the watchdog is in any non-NORMAL state).

Deliverable: a recorder that survives device churn and Bug B unattended.

DONE WHEN: the full watchdog simulation suite passes, **including the genuine-silence-forever zero-rebuild case** (10.1.2); manually switching the default output mid-recording yields a new segment + `deviceSwitch` event with capture continuing; changing the device rate in Audio MIDI Setup mid-recording rotates a segment at the new rate; unplugging a `.fixed` device enters `WAITING_FOR_DEVICE` and replugging resumes.

### Phase 4 — Per-app capture & multi-track (historical — later removed)

Tasks: full `ProcessCatalog` (§4 property constants, 1 Hz gated polling); `SessionSpec` `.appSet` sources (single mixed tap for multiple apps; one-lane-per-app when `multiTrack=true`); bundle-id AppSelectors surviving relaunch; per-lane folders/slugs; `mHostTime`-based cross-lane alignment in the manifest; CLI `--app`/`--multitrack`/`systemaudiorecorder apps`.

Deliverable: CLI can record one app, several apps mixed, or several apps as separate tracks.

DONE WHEN: recording `com.apple.Music` while a second app plays captures ONLY Music (the other app is absent by ear and by meter); a two-app multitrack session produces two lane folders whose first-buffer host times align the tracks within ±10 ms when loaded into a DAW.

**Post-v1 note:** per-app capture and multi-track (`.appSet`, `AppSelector`, `SessionSpecPlanner`/`LanePlan`, CLI `--app`/`--multitrack`) were removed after this phase shipped — a global tap already captures whatever is playing, and maintaining per-app isolation as a second capture path wasn't worth the surface area (Section 3.4). `ProcessCatalog` and `systemaudiorecorder apps` remain, now serving only the exclusion-list editor and app-activity triggers.

### Phase 5 — GUI app: menu bar, onboarding, Library

Tasks: NSStatusItem app per §3 (LSUIElement, SwiftUI-in-AppKit); menu-bar dropdown (record/stop, source picker, device+rate readout, 20 Hz meters, health chip); `PermissionBroker` + onboarding sheet + denial deep-link (§9); Library window (sessions list, badges, detail/events timeline, reveal in Finder); Settings window shell; disk guard.

Deliverable: the double-clickable product a non-CLI user can operate.

DONE WHEN: the full permission checklist (10.6, app portion) passes from a `tccutil` reset; a recording started and stopped from the menu bar shows live meters and the correct health chip through a forced rebuild — forced by switching the default output device mid-recording, which triggers a full lane rebuild (§7/§8); the chip must show ⚠ Rebuilding during it; the Library lists a crash-recovered session with its "recovered" badge.

### Phase 6 — ExportService

Tasks: transcodes from the CAF master only (§6): FLAC 16/24, ALAC 16/24, AAC ~256 kbps VBR, WAV 24-bit (compatibility-only copy in UI); TPDF dither default-ON for 16-bit; optional gain compensation hook (profile applied in Phase 7); Library export panel + `systemaudiorecorder export` verb; honest "lossless" labeling copy (§6); exports carry basic metadata from `session.json` (session title, date, source app/device) written via the container's standard tags.

Deliverable: shareable files in every supported format.

DONE WHEN: each format decodes and matches the master's duration/frame count; FLAC and ALAC exports, decoded back to PCM, are bit-identical to the pre-encode int buffers; a 16-bit export with dither OFF vs ON differs only at the LSB level; an exported file shows the session metadata (title, date, source) in Finder/Music; WAV is never offered as a master anywhere in UI or CLI.

### Phase 7 — CalibrationService & Bug-A UX

Tasks: consent dialog → play 997 Hz sine at −20 dBFS for 5 s through the target device via a temporary lane → measure middle-3 s RMS → store `gainCompensationDB` profile keyed `(deviceUID, outputChannelCount, macOSBuild)` (§8); >2-channel heuristic badge; compensated meters with "cal" badge; export-time compensation toggle; "Bake into master" advanced setting default OFF; `systemaudiorecorder calibrate` + Bug-A risk flag in `systemaudiorecorder devices`.

Deliverable: measured, per-device level trust.

DONE WHEN: the Bug-A test (10.4) passes: 2-channel calibration within ±0.5 dB of 0; on a multichannel device the profile matches the null-test-measured offset within ±0.5 dB; masters with and without a profile are bit-identical.

### Phase 8 — Automation surface

Tasks: all CLI verbs + exit codes from §3; URL scheme (`systemaudiorecorder://record/start|stop`); App Intents (Start/Stop/Get Status); shell hooks (`onSessionStart`, `onSegmentClose`, `onSessionFinalize` with `SYSTEMAUDIORECORDER_*` env vars, 30 s timeout); `TriggerEngine` schedules + app-activity auto-record (1 Hz, `hangTime` 10 s, document the ~1 s lead-in limitation); `HotkeyCenter` (default ⌃⌥⌘R).

Deliverable: fully scriptable recorder.

DONE WHEN: a scripted matrix exercises every CLI verb and asserts documented exit codes (0/2/3/4/5/64); a Shortcuts shortcut starts and stops a recording; each hook fires exactly once with correct env vars; an armed app trigger starts within ~1 s of first output and stops after 10 s of silence; the hotkey toggles recording with the app in the background.

### Phase 9 — Hardening & ship

Tasks: run the full Section 10 battery — null test with baseline capture (10.3), Bug-A test (10.4), 24 h Bug-B soak with the 2 h silence window (10.5), permission matrix (10.6), 4 GB+ and crash tests (10.7); re-verify every still-open "verify hands-on" item in §11 on the current macOS build (Bug A/Bug B presence, mic entitlement, settings deep-link anchor, DRM behavior — R6 is retired, Section 11); finalize the notarization pipeline on a DMG; optional Sparkle 2 integration; write user docs + the diagnostics guide (`systemaudiorecorder diag`).

Deliverable: the notarized, distributable release.

DONE WHEN: every Section 10 gate passes or is recorded to baseline; `nulltest-baseline.json` is captured and archived for the release machine; the soak shows zero false rebuilds in the silence window; a clean Mac downloads the DMG, passes Gatekeeper, completes onboarding, and records — with §11's re-verification results written into the release notes.
