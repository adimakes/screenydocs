# Chapter 5 — Extension Architecture

Screeny has three App Extension targets beyond the main app. Each runs in its own sandboxed process with specific capabilities and constraints.

---

## Extension 1: ScreenyDeviceMonitor

**Type:** `DeviceActivityMonitor` extension  
**Bundle ID:** `com.adityabhatia.screeny.ScreenyDeviceMonitor`  
**Entry point:** `DeviceActivityMonitorExtension` subclasses `DeviceActivityMonitor`  
**Source:** Single file: `DeviceActivityMonitorExtension.swift` (~700 lines)

### What it can do
- Receive `intervalDidStart` / `intervalDidEnd` / `eventDidReachThreshold` callbacks from `DeviceActivityCenter`
- Read and write to the App Group
- Write to `ManagedSettingsStore("screenyScheduleRestrictions")`
- Schedule local push notifications via `UNUserNotificationCenter`

### What it cannot do
- Import or call any main app code
- Make network requests
- Access SwiftData
- Register new `DeviceActivityCenter` activities (only the main app can do this)

### Memory constraints
The monitor extension is a background process with a very tight memory budget (typically 15-30 MB). OOM kills are silent — iOS simply stops delivering callbacks. The extension tracks available memory via `os_proc_available_memory()` and writes the worst observed free KB to `"extMemWorstFreeKB"` in the App Group. This metric is visible in Settings for debugging.

### Callback map

```
intervalDidStart(activity: DeviceActivityName)
    │
    ├── activity == "screeny.heartbeat"
    │       └── performDailySelfHeal(reason: "heartbeat")
    │           ├── Reset statsDailyTotal = 0
    │           ├── Reset statsDaily_<UUID> = 0 for all flows
    │           ├── Stamp statsLiveDays with today's key
    │           └── Rebuild schedule shield union
    │
    ├── activity starts with "screeny.flow."
    │       ├── Extract flowIDString
    │       ├── Check: is this flow's schedule in-window? (isInWindow)
    │       ├── Stamp statsLiveDays with today's key
    │       └── buildAndApplyScheduleShield()
    │
    ├── activity starts with "screeny.stats"
    │       ├── Stamp statsLiveDays (liveness proof for stats)
    │       └── (stats tick recording handled in eventDidReachThreshold)
    │
    └── activity starts with "screeny.coach"
            └── buildCoachLadderShield()

intervalDidEnd(activity: DeviceActivityName)
    │
    ├── activity starts with "screeny.flow."
    │       ├── Remove this flow from the schedule shield union
    │       ├── If flow had a usage limit: reassertSpentLimitAtWindowEnd()
    │       └── buildAndApplyScheduleShield()
    │
    └── activity starts with "screeny.relock."
            ├── Read TimedRelockEntry from App Group
            ├── Re-apply wasManual / wasSchedule / wasLimit sources
            └── Write UnlockLedgerEntry(kind: .relock)

eventDidReachThreshold(event: DeviceActivityEvent, activity: DeviceActivityName)
    │
    ├── event name ends with ".warn80"
    │       └── scheduleRelockWarningNotification() (or warn80 push)
    │
    ├── event name starts with "st_" (union stats tick)
    │       ├── Parse tick value from event name
    │       ├── max()-write statsDailyTotal (never go backward)
    │       └── Stamp statsLiveDays
    │
    ├── event name starts with "sf_<UUID>_" (per-flow stats tick)
    │       ├── Parse flowID and tick value
    │       └── max()-write statsDaily_<UUID>
    │
    └── event name ends with ".<N>min" for a limit event
            ├── Set usageLimitTriggered_<UUID> = true
            ├── buildAndApplyUsageLimitShield() — adds this flow to schedule store
            └── Post local notification (if warn80Enabled and this is the 80% event)
```

### Shield rebuild: the union pattern

The monitor extension never just applies one flow's shield. It always rebuilds the union:

```swift
private func buildAndApplyScheduleShield() {
    // 1. Read all scheduledFlowMetas from App Group
    // 2. Filter to flows whose window is currently active (isInWindow)
    // 3. For each active flow, read flowAppSelection_<uuid>
    // 4. Distinguish block-mode vs allow-only flows
    // 5. Build UnionState:
    //    - block flows: union of all blocked selections
    //    - allow-only flows: intersection of allowed sets (most restrictive)
    // 6. Apply to ManagedSettingsStore("screenyScheduleRestrictions")
}
```

Allow-only union semantics: if two allow-only flows are simultaneously active, the allowed set is the *union* of their allowlists (more permissive), not the intersection. This is intentional — a night schedule that allows the alarm app should not fight a focus schedule that allows work apps.

### Duplicate struct definitions

Because the extension cannot import the main app, all shared types are duplicated:

```
ExtScheduleMeta     = ScheduledFlowMeta     (main app equivalent)
ExtRelockEntry      = TimedRelockEntry
ExtBlockEntry       = ActiveBlockEntry
ExtUnlockLedgerEntry = UnlockLedgerEntry
```

These must stay in sync. Any field addition to a main-app struct must be mirrored to the extension's copy. The extension uses `= nil` defaults for optional fields, ensuring old blobs written by the main app can be decoded by the extension.

---

## Extension 2: ScreenyShieldConfig

**Type:** `ShieldConfiguration` extension  
**Bundle ID:** `com.adityabhatia.screeny.ScreenyShieldConfig`  
**Entry point:** `ShieldConfigurationExtension` subclasses `ShieldConfigurationDataSource`  
**Source:** `ShieldConfigurationExtension.swift`

### What it does

When an app is blocked by a shield, iOS calls this extension to provide a custom UI. The extension returns a `ShieldConfiguration` object with:
- A custom icon (the Screeny ghost — `ShieldGhost` vector asset, cream fill)
- Title text
- Subtitle text (one of 6 rotating ghost lines, personalized with the user's name)
- Button title ("Close")

### Ghost lines

Six rotating lines personalized with `screenyUserName` from the App Group:
1. "Boo. Just me."
2. "I'm protecting you from [App], that was the deal."
3. "Take a breath."
4. "This one's not for you right now."
5. "You set this up. I'm just doing my job."
6. "Step away. You'll thank me later."

The line index is derived from the current hour-of-day so it changes through the day but stays consistent within a session.

### App name harvesting

When the shield renders for an app, this extension can call `Application(token:).localizedDisplayName` and get the *real* name (this API works in shield extensions under individual authorization). The extension stores this in the App Group:

```swift
let names = defaults.dictionary(forKey: "harvestedAppNames") ?? [:]
let key = try? JSONEncoder().encode(applicationToken)
names[key.base64EncodedString()] = displayName
defaults.set(names, forKey: "harvestedAppNames")
```

The main app reads these harvested names on next launch via `ScreenyAppNames.harvested(for:)`. Over time, every app the user has ever been blocked from gets its real name stored and rendered in the app's own font.

### Why no ShieldAction extension

The `ScreenyShieldAction` extension target was removed during App Store validation prep. `com.apple.ManagedSettingsUI.shield-action-service` is not a valid standalone extension point and App Store validation rejected it. The "Close" button works via iOS default shield behavior — iOS automatically wires the close button when no action extension is present.

---

## Extension 3: ScreenyActivityReport

**Type:** `DeviceActivityReport` extension  
**Bundle ID:** `com.adityabhatia.screeny.ScreenyActivityReport`  
**Entry point:** `ScreenyActivityReport.swift` registers scenes  
**Source:** 4 files

### What it does

This extension renders SwiftUI views inside the host app. The host app creates a `DeviceActivityReport` view with a filter; the extension renders the actual usage data inside it. The extension runs in a separate process and the rendered pixels are composited into the host's view hierarchy.

### Current scenes

| Scene name | View | Where used |
|---|---|---|
| `TotalActivity` | `TotalActivityView` | Home tab usage card |
| `WeeklyActivity` | (weekly report) | Weekly stats notification |

The stats-trend scenes (`Stats Trend 7/30/Year/All`, `Stats Totals`) were **removed** in build 20. They were replaced by the app-drawn chart in `StatsTabView`. The reasons:
1. The extension does not receive touch events — interactive charts were impossible
2. The extension cannot write to the App Group — numbers could not be surfaced in the main app
3. Cold-start delay on every tab open was noticeable

### The cold-start problem and hosting cache

`UsageReportView.swift` implements `StatsReportHostCache` — a persistent pool of `UIHostingController` objects. Each report surface gets its own controller that is never deallocated when the tab closes. Re-opening the tab reattaches the existing controller's view, showing the last-rendered pixels instantly.

Refresh policy:
- Stale after 15 minutes or a day change → render a new layer at opacity 0, crossfade after 3-second timeout
- Day change → hard reset (one cold-start per day is acceptable)

### Touch events: why the extension can't be interactive

The extension's SwiftUI view is rendered in a separate process. The host's `UIView` is a remote rendering surface — touches are delivered to the host process, not forwarded to the extension. Any `onTapGesture` or `DragGesture` inside the extension view silently receives nothing. This is the root cause of the "tooltips don't work" bug that prompted the stats tab rebuild.

---

## Extension lifecycle: what kills them

All three extensions are background processes. iOS can kill them at any time for memory pressure, inactivity, or system limits. Key scenarios:

**DeviceMonitor OOM kill:** If the extension runs out of memory while processing a stats tick, it is killed silently. The next `intervalDidStart` will restart the extension process. No ticks are delivered for the killed window. This is tracked via `extMemWorstFreeKB` — if this value is consistently below ~5,000 KB, the extension is in danger of OOM kills and the stats ladder should be simplified.

**ShieldConfig extension timeout:** iOS gives the shield config extension a tight rendering deadline. If the extension takes too long (e.g. rasterizing a large vector icon at full resolution), iOS falls back to the default shield. The `ShieldGhost` icon is a crisp vector asset specifically sized to avoid this — if the asset is replaced with a raster image, use a small PNG (128×128 or 256×256) to avoid OOM kills on older devices (iPhone 13/14 with limited extension memory).

**ActivityReport stale extension:** If the report extension process is stale (killed since last use), the first render request after re-attaching can take 2-5 seconds. This is why the hosting cache was built — to show last-frame pixels while the extension warms up.

---

## Extension communication summary

```
Main app ──────────────────────────────────────────────► Monitor extension
         schedules via DeviceActivityCenter              reads App Group on callbacks
         writes App Group (schedules, selections)        writes App Group (stats, lock state)

Main app ◄──────────────────────────────────────────────
         reads App Group (stats, lock state)

Main app ──────────────────────────────────────────────► Shield extension
         writes App Group (userName, language)           reads App Group (userName, language)
                                                         writes App Group (harvestedAppNames)

Main app ◄──────────────────────────────────────────────
         reads App Group (harvestedAppNames)

Main app ──────────────────────────────────────────────► Report extension
         DeviceActivityReport view in UIKit/SwiftUI      renders usage data (sandboxed)
         (remote render surface)                         CANNOT write App Group
```
