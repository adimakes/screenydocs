# Chapter 3 — Data Model & Inter-Process Communication

Screeny runs across four sandboxed processes. This chapter covers how data is modeled and how those processes share state without violating Apple's sandboxing rules.

---

## SwiftData models (main app only)

SwiftData is used exclusively in the main app. Extensions cannot access the SwiftData store.

### Flow

The central entity. One Flow = one trigger → action rule that can lock/unlock apps.

```
Flow (@Model)
│
├── Identity
│   ├── id: UUID
│   ├── name: String              ← display name (catalog apps: real name; picker: "App" until resolved)
│   ├── createdAt: Date
│   └── isEnabled: Bool
│
├── Tile classification
│   ├── tileKindRaw: String       ← "singleApp" | "folder" | "category"
│   └── blockingModeRaw: String   ← "block" | "allowOnly"
│
├── App selection
│   ├── selectedAppsData: Data?   ← encoded FamilyActivitySelection (authoritative on device)
│   └── appGroupID: UUID?         ← reference to App Group selection key
│
├── Trigger (v2 blob + legacy flat fields)
│   ├── triggerData: Data?        ← JSON-encoded WorkflowTrigger (v2, authoritative)
│   ├── triggerType: String       ← legacy: "nfc" | "qr" | "schedule" | etc.
│   ├── triggerToken: String?     ← scan payload that activates/deactivates this flow
│   ├── scheduleStartHour/EndHour ← schedule window
│   ├── scheduleWeekdays: [Int]?  ← 0=Mon … 6=Sun
│   └── keyID: UUID?              ← FK to Key
│
├── Blocking (v2 blob + legacy flat fields)
│   ├── blockingData: Data?       ← JSON-encoded BlockingStrategy (v2, authoritative)
│   ├── actionType: String        ← legacy: "block" | "blockForDuration" | "unblock"
│   ├── durationMinutes: Int?     ← block timer duration
│   ├── hardcoreMode: Bool        ← refuses all unlock except exact token
│   ├── weekendLimitMinutes: Int? ← weekend override for daily limit
│   └── warn80Enabled: Bool       ← fire push at 80% of daily limit
│
├── Breaker (v2 blob + legacy flat field)
│   ├── unblockData: Data?        ← JSON-encoded WorkflowBreaker (v2, authoritative)
│   └── unblockModeRaw: String?   ← legacy breaker mode
│
├── Schema migration
│   └── schemaVersion: Int        ← 0=legacy, 2=blobs populated
│
└── Computed properties
    ├── tileKind: FlowTileKind    ← typed from tileKindRaw
    ├── blockingMode: ScreenyBlockingMode
    ├── isFolder: Bool
    ├── hasDailyLimit: Bool       ← nil vs 0 distinction: nil=no limit, 0=blocked all day
    ├── effectiveDailyLimitMinutes: Int? ← honors weekend override
    ├── isZeroLimitToday: Bool
    ├── isCurrentlyInScheduleWindow: Bool
    ├── primaryAppToken: ApplicationToken?
    └── displayName: String       ← catalog name | harvested | "App"
```

**Schema evolution:** v1→v2 migration runs in `migrateIfNeededV1ToV2()`. This copies flat fields into the blob columns and sets `schemaVersion = 2`. It is called lazily on Flow reads. Because the blob columns are additive, the migration is backward-compatible — an older build can still read the flat fields.

### Key

```
Key (@Model)
├── id: UUID
├── name: String             ← user-given label
├── token: String            ← the scan payload (NFC UID or QR content)
├── keyType: String          ← "nfc" | "qr"
├── createdAt: Date
└── iconName: String?        ← SF Symbol or catalog icon
```

One Key can be assigned to multiple Flows via `Flow.keyID`. When a scan matches `Key.token`, all flows with that key become candidates for the lock/unlock action.

---

## App Group UserDefaults schema

The App Group (`group.com.adityabhatia.screeny`) is the only data channel between all four processes. It uses `UserDefaults` with suite name `"group.com.adityabhatia.screeny"`.

### Key inventory (complete)

#### Blocking state

| Key | Type | Written by | Read by | Description |
|---|---|---|---|---|
| `activeBlockEntries` | `Data` (JSON `[ActiveBlockEntry]`) | main app | main app, monitor ext | Currently manually locked flows (the union shield) |
| `activeBlockingState` | `Data` (JSON `ActiveBlockingState`) | main app | main app | Legacy single-block state; superseded by entries |
| `temporaryReleaseState` | `Data` (JSON `TemporaryReleaseState`) | main app | main app, monitor ext | Active breather/temporary release |
| `scheduledFlowMetas` | `Data` (JSON `[UUID: ScheduledFlowMeta]`) | main app | monitor ext | Schedule window definitions for union rebuild |
| `scheduledFlowIDs` | `Data` (JSON `[UUID]`) | main app | main app | Which flows have active schedules registered |
| `usageLimitState` | `Data` (JSON `UsageLimitState`) | main app | monitor ext | Which flows have threshold monitoring active |
| `timedRelockEntries` | `Data` (JSON `[TimedRelockEntry]`) | main app, monitor ext | both | Pending re-locks from timed unlocks |
| `unlockLedger` | `Data` (JSON `[UnlockLedgerEntry]`) | main app, monitor ext | both, BingeBrain | Rolling unlock history for anti-binge |

#### Per-flow selections

| Key | Type | Written by | Read by | Description |
|---|---|---|---|---|
| `flowAppSelection_<UUID>` | `Data` (JSON `FamilyActivitySelection`) | main app | monitor ext | Authoritative app selection per flow |
| `allowOnlyFlowIDs` | `Data` (JSON `[String]`) | main app | monitor ext | Which flow IDs are allow-only mode |
| `unlockedAppExceptions` | `Data` ([`Data`]) | main app | monitor ext | Per-app exceptions for allow-only pierce |

#### Statistics

| Key | Type | Written by | Read by | Description |
|---|---|---|---|---|
| `statsDailyTotal` | `Int` | monitor ext | main app | Today's union usage in minutes (tick-grade) |
| `statsDaily_<UUID>` | `Int` | monitor ext | main app | Today's per-flow usage in minutes |
| `statsHistory` | `Data` (JSON `[String: Int]`) | monitor ext | main app | Union daily history (key = "YYYY-MM-DD") |
| `statsFlowHistory_<UUID>` | `Data` (JSON `[String: Int]`) | monitor ext | main app | Per-flow daily history |
| `statsLiveDays` | `Data` (JSON `[String]`) | monitor ext, main app | main app | Days with a confirmed liveness stamp (non-phantom) |
| `statsTrackingStart` | `Double` (timeInterval) | main app | main app, monitor ext | Date screeny started tracking (for "since we started") |
| `statsSignature` | `String` | main app | monitor ext | Ladder version string ("v4|...") triggers re-arm |

#### Coach (anti-binge)

| Key | Type | Written by | Read by | Description |
|---|---|---|---|---|
| `coachSelectionData` | `Data` | main app | monitor ext | Union of coach-paced apps |
| `coachDirtyKey` | `String` | main app | main app (KVO) | Incremented to trigger coach re-arm |
| `coachExcludedAppTokens` | `Data` | main app | main app | Apps excluded from coach pacing |

#### UI mirrors

| Key | Type | Written by | Read by | Description |
|---|---|---|---|---|
| `screenyUserName` | `String` | main app | shield ext, monitor ext | User's name for personalization |
| `screenyLanguage` | `String` | main app | all extensions | "en" or "de" |
| `harvestedAppNames` | `Dict<String, String>` | shield ext | main app | base64(token) → display name |

#### Usage limits (legacy / transient)

| Key | Type | Description |
|---|---|---|
| `usageLimitTriggered_<UUID>` | `Bool` | Set by monitor when a limit fires; cleared by first unlock of the day |
| `limitSpentDay_<UUID>` | `String` | YYYY-MM-DD stamp of the day limit was spent |

---

## IPC patterns

### Write-then-read (main app → monitor)

The main app writes a schedule definition to `scheduledFlowMetas`, then calls `DeviceActivityCenter.startMonitoring()`. The monitor extension reads the metas when `intervalDidStart` fires. This is the only way to "call" the extension.

```
Main app:                          Monitor extension:
  1. Write scheduledFlowMetas ────► read on intervalDidStart
  2. startMonitoring()          ──► calls intervalDidStart
  3. (no return path)
```

### KVO observation (cross-process)

The monitor extension writes `statsDailyTotal` using `UserDefaults.set`. The main app observes this via `StatsHistoryWatcher`, which registers KVO on the App Group defaults. When a tick lands while the Stats tab is open, the chart morphs live.

```
Monitor ext:    writes statsDailyTotal
     ↓  (UserDefaults sync, ~100ms)
Main app:       KVO fires → StatsHistoryWatcher → StatsTabView.rebuild()
```

### One-way fire-and-forget (monitor → main)

The monitor writes to the unlock ledger and blocking state. The main app reads these on foreground and on `onAppear`. There is no push mechanism from the monitor to the app — the app must poll on activation.

---

## Struct definitions: the IPC contract types

These structs are defined in `SharedDefaults.swift` in the main app and **duplicated inline** in the monitor extension. They must stay byte-for-byte compatible because both processes encode/decode the same `Data` blobs.

```swift
struct ActiveBlockEntry: Codable {
    var flowID: UUID
    var hardcoreMode: Bool
    var blockStartDate: Date
    var blockDurationMinutes: Int?
    var selectedActivityData: Data?
    var allowOnly: Bool? = nil         // optional for backward compat
}

struct TimedRelockEntry: Codable {
    var flowID: UUID
    var unlockDate: Date
    var relockDate: Date
    var wasManual: Bool
    var wasSchedule: Bool
    var wasLimit: Bool
    var wasGroup: Bool? = nil          // optional for backward compat
}

struct ScheduledFlowMeta: Codable {
    var startMinutes: Int              // minutes since midnight
    var endMinutes: Int
    var weekdays: [Int]                // 0=Mon … 6=Sun
}

struct UnlockLedgerEntry: Codable {
    enum Kind: String, Codable { case unlock, fullUnlock, relock, pause }
    var date: Date
    var kind: Kind
    var flowID: UUID?
    var grantedMinutes: Int?
    var overLimit: Bool?
}
```

**Backward compatibility rule:** Never remove or rename fields in these structs. Adding optional fields with `= nil` defaults is always safe because `JSONDecoder` ignores unknown keys by default and supplies `nil` for missing optional fields.

---

## App Group: known fragility

### cfprefsd caching
The UserDefaults system routes through the `cfprefsd` daemon. There is a known issue where simulator writes from the host (Xcode console `defaults write`) land in the host's `cfprefsd` cache and never reach the simulator's container. The correct way to seed the simulator:

```bash
xcrun simctl spawn <UDID> defaults export <full_path_to_plist_without_extension>
# ... modify with plistlib in Python (to preserve types) ...
xcrun simctl spawn <UDID> defaults import <full_path_to_plist_without_extension>
```

Using `defaults write -dict` types values as strings; `dictionary(forKey:) as? [String: Int]` then silently drops them. Use Python's `plistlib` to write typed integer values.

### Extension sandbox on device
The ActivityReport extension cannot write to the App Group on real devices (sandbox-denied). This was verified on TestFlight build 3 — the extension's App Group writes silently fail even though the entitlement is declared. The DeviceMonitor extension can write normally. This is why stats moved entirely to the tick-ladder approach and the ActivityReport extension was stripped of its write paths.
