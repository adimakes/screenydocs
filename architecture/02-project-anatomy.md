# Chapter 2 — Project Anatomy

Complete map of every file, folder, and target in the Screeny Xcode project.

---

## Build configuration

| Setting | Value |
|---|---|
| `CURRENT_PROJECT_VERSION` | 24 (all 8 target occurrences) |
| `MARKETING_VERSION` | 1.0 |
| `IPHONEOS_DEPLOYMENT_TARGET` | 17.4 |
| Bundle ID | `com.adityabhatia.screeny` |
| App Group | `group.com.adityabhatia.screeny` |
| Team | `6J32B8W8BF` |

---

## Targets (4 total)

```
screeny                       ← main app
ScreenyDeviceMonitor          ← DeviceActivity monitor extension
ScreenyShieldConfig           ← ManagedSettings shield configuration extension
ScreenyActivityReport         ← DeviceActivity report extension
```

All four targets carry the `com.apple.developer.family-controls` entitlement and the App Group `group.com.adityabhatia.screeny`. The main app additionally holds the NFC entitlements (`com.apple.developer.nfc.readersession.formats`: TAG, PACE).

---

## File tree: main app (`screeny/`)

### Root level
```
screeny/
├── screenyApp.swift           ← @main, SwiftData container setup, language/shield mirror
├── ContentView.swift          ← Root gating: onboarding vs main shell; language key
├── Config.swift               ← MOCK_SCREEN_TIME flag, app constants
├── Info.plist                 ← bundle config, NFC usage string, background modes
└── screeny.entitlements       ← family-controls, NFC (TAG+PACE), App Group
```

**`screenyApp.swift`:** Sets up the SwiftData `ModelContainer` with the `Flow` and `Key` schema. Calls `mirrorShieldState()` on launch and background (mirrors `screenyUserName`, `screenyLanguage`, and blocking state into the App Group so extensions can read them). Applies the persisted dark/light/system theme.

**`Config.swift`:** Contains `let MOCK_SCREEN_TIME = false`. When `true`, all blocking calls are replaced with log output, enabling simulator development without the Screen Time permission flow. The ~30 guard sites are scattered through AppBlocker, FlowEngine, CanvasViewModel, and FamilyControlsAuthManager. **Never set this to `true` in a release build.**

---

### `Core/`
```
Core/
├── FlowEngine.swift           ← 2,400+ lines, the entire blocking engine (see Chapter 4)
└── BingeBrain.swift           ← Anti-binge evaluator (coach pacing, breather decisions)
```

**`FlowEngine.swift`:** The single entry point for all blocking operations. Owns `ManagedSettingsStore("screenyRestrictions")`, all `DeviceActivityCenter` registrations, relock scheduling, and shield reconciliation. `@MainActor ObservableObject`. See Chapter 4 for full detail.

**`BingeBrain.swift`:** Evaluates the unlock ledger to decide whether to offer a breather, which tier (Gentle/Balanced/Strict), and when the coach ladder should escalate. Reads `UnlockLedgerEntry` entries from the App Group.

---

### `Models/`
```
Models/
├── Flow.swift                 ← @Model, the core rule entity (see Chapter 3)
├── FlowEnums.swift            ← TriggerKind, ActionKind, BreakerMode
├── Key.swift                  ← @Model, NFC/QR key entities
├── AppGroup.swift             ← App Group model (not SwiftData — convenience wrapper)
└── WorkflowConfigs.swift      ← WorkflowTrigger, BlockingStrategy, WorkflowBreaker structs
```

**`Flow.swift`:** The central SwiftData model. A Flow is one trigger → action rule. Critical fields:
- `triggerType` (raw `TriggerKind`): nfc / qr / barcode / schedule / manual / appUsageLimit
- `blockingModeRaw` (raw `ScreenyBlockingMode`): block / allowOnly
- `tileKindRaw` (raw `FlowTileKind`): singleApp / folder / category
- `scheduleStartHour/EndHour/Weekdays`: schedule window definition
- `hardcoreMode`: refuses all unlock attempts except the exact scan token
- Schema versioning: v0 = legacy flat fields, v2 = structured blob columns (`triggerData`, `blockingData`, `unblockData`)

**`Key.swift`:** A scan token (NFC tag UID or QR code payload). Keys are assigned to flows. One key can unlock many flows. `triggerToken` on `Flow` mirrors the key's token string.

**`WorkflowConfigs.swift`:** Three Codable structs (`WorkflowTrigger`, `BlockingStrategy`, `WorkflowBreaker`) that represent the v2 blob columns. These exist so the schema can evolve without SwiftData migrations — adding a field to the struct is backward-compatible via `JSONDecoder`.

---

### `Shared/`
```
Shared/
├── SharedDefaults.swift       ← App Group UserDefaults wrapper + all key definitions
└── ScreenyStatsStore.swift    ← Stats tick history reader/writer (App Group side)
```

**`SharedDefaults.swift`:** The single source of truth for the App Group schema. Every App Group key is defined here as a typed property. All four processes use compatible copies of the key strings (the monitor extension embeds a private copy of key-name constants to avoid importing main app code). Key categories:
- Blocking state: `activeBlockEntries`, `activeBlockingState`, `temporaryReleaseState`
- Schedules: `scheduledFlowMetas`, `usageLimitState`  
- Re-locks: `timedRelockEntries`
- Stats: `statsDailyTotal`, `statsDaily_<UUID>`, `statsLiveDays`, `statsTrackingStart`
- Coach: `coachSelectionData`, `coachDirtyKey`
- UI mirrors: `screenyUserName`, `screenyLanguage`, `harvestedAppNames`

**`ScreenyStatsStore.swift`:** Reads and writes the tick-history arrays. `StatsHistory` struct bundles the `[String: Int]` day-keyed values with the ladder definition they were sampled on, so a reader can never resolve ticks against the wrong grid.

---

### `ScreenTime/`
```
ScreenTime/
├── AppBlocker.swift           ← ManagedSettingsStore("screenyRestrictions") wrapper
├── FamilyControlsAuthManager.swift  ← authorization request + status
└── UsageReportView.swift      ← UIHostingController scaffolding for ActivityReport ext
```

**`AppBlocker.swift`:** Thin wrapper around `ManagedSettingsStore(named: "screenyRestrictions")`. Only called by `FlowEngine`. All blocking calls go through here. The store name is important: the monitor extension uses `"screenyScheduleRestrictions"` so the two stores compose rather than clobber each other.

**`UsageReportView.swift`:** Hosts `DeviceActivityReport` views (the usage card on the home screen and the weekly activity report). Implements `StatsReportHostCache` — a persistent `UIHostingController` pool that survives the tab closing, so re-opening shows last-rendered pixels instantly rather than waiting for the extension's cold start.

---

### `Triggers/`
```
Triggers/
├── NFCScannerService.swift    ← CoreNFC NFC tag reader (NFCTagReaderSession)
├── QRScannerService.swift     ← AVFoundation QR + barcode scanner
└── ScanCoordinator.swift      ← routes scan results to FlowEngine
```

**NFCScannerService:** Uses `NFCTagReaderSession` (not `NFCNDEFReaderSession` — the NDEF format was removed from the entitlements per App Store validation feedback). Reads NDEF content via `mifareTag.readNDEF`. The session must be started from a user gesture; it cannot be backgrounded or auto-started.

---

### `Intents/`
```
Intents/
├── LockFlowIntent.swift       ← AppIntent for Siri/Shortcuts (lock a flow by name)
├── UnlockFlowIntent.swift     ← AppIntent for Siri/Shortcuts (unlock a flow)
└── ToggleFlowIntent.swift     ← AppIntent for Siri/Shortcuts (toggle a flow)
```

AppIntents follow the *system* language, not Screeny's in-app language setting. This is intentional — Siri prompts are expected to match the device language.

---

### `UI/`
```
UI/
├── MainShellView.swift        ← TabView host (Home/Scan/Keys/Stats), settingsTarget state
├── CanvasViewModel.swift      ← Main state machine: flows, blocking decisions, unlock
│
├── Home/
│   ├── HomeWorkflowView.swift ← Home tab: streak, flows list, usage card, coach card
│   ├── FlowDetailView.swift   ← Single-app flow detail: lock/unlock, stats, key
│   ├── FolderDetailView.swift ← Folder detail: member list, lock/unlock
│   └── UsageCard/             ← Home usage summary (report extension host)
│
├── Stats/
│   ├── StatsTabView.swift     ← Stats tab root: headline, chart card, trend rows
│   ├── StatsChartData.swift   ← StatsScope, StatsRange, StatsChartPage, StatsTrendRow
│   ├── StatsTrendChart.swift  ← StatsTrendCard: chart, header, range controls
│   ├── StatsTrendRows.swift   ← Trend rows card
│   └── StatsTheme.swift       ← ST tokens (blue=down, amber=up), statsGlass, aurora
│
├── Onboarding/
│   ├── OnboardingFlowView.swift ← 11-step onboarding coordinator
│   └── (step views)
│
├── Settings/
│   ├── SettingsSheetView.swift  ← Settings sheet root + all editor entry points
│   ├── RuleConfigViews.swift    ← Schedule/limit/break editors
│   ├── CoachEditor.swift        ← Personalized breaks mode + exclusion strip
│   └── NotificationsEditor.swift← Notification toggle rows
│
├── AppPicker/
│   └── AppLibraryPickerView.swift ← Wraps FamilyActivityPicker, strips categories
│
├── Camera/
│   ├── CameraScannerView.swift  ← Scan tab: camera + NFC toggle
│   └── ScanFeedbackCapsule.swift← HUD toast for scan results
│
├── Components/                  ← Shared: BigNumberPicker, ScreenyEditorScaffold,
│   └── (many)                     LockedNoticeCenter, FirstUseCoach, etc.
│
└── Theme/
    ├── ScreenyTheme.swift       ← Theme tokens, dynamic palette
    └── ScreenyDesignComponents.swift ← Shared component library
```

---

### `Localizable.xcstrings`
The single String Catalog for the main app. ~340 keys, English + German. All user-facing strings go through `t("key")` (defined in `ScreenyL10n.swift`). The catalog is the source of truth — the old `ScreenyStrings` table was deleted.

---

## File tree: ScreenyDeviceMonitor extension

```
ScreenyDeviceMonitor/
├── DeviceActivityMonitorExtension.swift  ← the entire extension (~700 lines)
├── Info.plist
├── Localizable.xcstrings                 ← warn80 push, stats push strings
└── ScreenyDeviceMonitor.entitlements     ← family-controls, App Group
```

This is a single-file extension. It cannot import any main app module. All shared types (struct definitions for App Group values) are duplicated inline. See Chapter 5 for the full callback map.

---

## File tree: ScreenyShieldConfig extension

```
ScreenyShieldConfig/
├── ShieldConfigurationExtension.swift    ← draws the custom shield screen
├── Assets.xcassets                       ← ShieldGhost vector, backgrounds
├── Localizable.xcstrings                 ← ghost lines + "Close" button
├── Info.plist
└── ScreenyShieldConfig.entitlements      ← family-controls, App Group
```

This extension draws the cheerful Screeny block screen. It reads `screenyUserName` from the App Group to personalize the ghost lines. It also harvests app display names into `"harvestedAppNames"` when a shield shows — the only mechanism by which the main app can eventually learn an app's real name.

---

## File tree: ScreenyActivityReport extension

```
ScreenyActivityReport/
├── ScreenyActivityReport.swift     ← extension entry point, scene registration
├── TotalActivityReport.swift       ← the home-screen usage card scene
├── TotalActivityView.swift         ← SwiftUI view for the usage card
├── WeeklyActivityReport.swift      ← weekly stats report (push notification trigger)
├── Localizable.xcstrings           ← report.* keys
└── ScreenyActivityReport.entitlements
```

This extension draws the home screen usage card and the weekly email-style report. It can read real Screen Time usage but **cannot write anything back to the main app** (see Chapter 1). It does not receive touch events.

---

## File tree: docs/

```
docs/
├── TESTFLIGHT-PREP.md              ← device-test checklist, TF3 build notes
├── family-controls-entitlement.md  ← step-by-step guide to request Distribution entitlement
├── stats-architecture-and-problem.md  ← the full stats design doc (23k bytes)
└── architecture/                   ← this book
    ├── 00-index.md
    ├── 01-apple-api-constraints.md
    ├── 02-project-anatomy.md       ← (this file)
    ├── ...
```

---

## File tree: reference/

```
reference/
├── foqos/                          ← Foqos open-source app (read-only reference)
└── ui-screenshots/                 ← Bevel and design reference screenshots
```

Do not edit `reference/foqos/`. It exists for comparison and inspiration only.

---

## Synchronized folder groups (no pbxproj wiring)

The `screeny/UI/Stats/` folder uses Xcode's **synchronized folder group** feature — files added to the folder on disk are automatically compiled without editing `project.pbxproj`. This means the four Stats files (`StatsChartData.swift`, `StatsTheme.swift`, `StatsTrendChart.swift`, `StatsTrendRows.swift`) have no explicit entries in `project.pbxproj`. They are included by the group rule.

If a new Stats file is ever created, it will be picked up automatically. All other folders use traditional explicit file references.

---

## Dependency summary: no SPM/CocoaPods

Screeny has **zero external dependencies**. The entire codebase uses only Apple frameworks:
- `FamilyControls`
- `ManagedSettings`
- `DeviceActivity`
- `SwiftData`
- `SwiftUI`
- `CoreNFC`
- `AVFoundation`
- `AppIntents`
- `UserNotifications`

This is a deliberate choice — no supply chain, no version conflicts, no App Store review friction from third-party code.
