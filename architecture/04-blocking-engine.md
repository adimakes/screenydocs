# Chapter 4 — Blocking Engine (FlowEngine)

`FlowEngine` is the nervous system of the app. Every lock, unlock, schedule, usage limit, relock, and breather flows through it. This chapter maps the entire state machine.

---

## Architecture overview

```
FlowEngine (@MainActor ObservableObject)
│
├── State                          ← what is currently locked/scheduled
│   ├── activeBlocks: [UUID: ActiveBlockEntry]
│   ├── scheduledFlowIDs: Set<UUID>
│   ├── usageLimitFlowIDs: Set<UUID>
│   ├── relockDates: [UUID: Date]
│   └── blockEndDate: Date?
│
├── ManagedSettings
│   └── AppBlocker.shared          ← writes to "screenyRestrictions" store
│
├── DeviceActivityCenter           ← registers/removes activities (20-slot ceiling)
│
└── SharedDefaults.shared          ← App Group IPC
```

FlowEngine is instantiated once in `CanvasViewModel` and lives for the app's lifetime. It is passed down to views via `@StateObject` / `@ObservedObject`.

---

## The three shield stores

Screeny uses three `ManagedSettingsStore` instances to avoid write conflicts:

| Store name | Owner | Content |
|---|---|---|
| `"screenyRestrictions"` | Main app (AppBlocker) | Manual locks triggered by user action |
| `"screenyScheduleRestrictions"` | Monitor extension | Schedule windows, usage limits, coach, stats |
| *(implicit: per-app exceptions)* | Both processes | `unlockedAppExceptions` for allow-only pierce |

Shield composition: the device shows an app as blocked if **any** store shields it. Unblocking from one store does not release a block held by another store. This is why unlocking a manual lock during an active schedule window still leaves the app blocked — the schedule store still holds it.

---

## Lock flow: manual trigger

```
User action (scan / tap)
        │
        ▼
CanvasViewModel.executeFlow(flow)
        │
        ▼
FlowEngine.executeFlow(flow)
        │
        ├── activateBlocking(flow, durationMinutes: nil)
        │       │
        │       ├── AppBlocker.activateBlock(selection, hardcoreMode)
        │       │       └── ManagedSettingsStore("screenyRestrictions")
        │       │           .shieldSettings.applicationLockdown = ...
        │       │
        │       ├── Write ActiveBlockEntry to App Group
        │       │
        │       └── If durationMinutes set: startDurationTimer()
        │
        └── scheduleDeviceActivity(for: flow)  ← if schedule/limit configured
```

**Multiple simultaneous locks:** `activeBlocks` is a `[UUID: ActiveBlockEntry]` dictionary. Each locked flow has its own entry. The shield applied to the device is always the **union** of all entries' app selections. This is computed by `applyUnionShield()` which iterates all entries and calls `AppBlocker.activateBlock()` with the combined selection.

---

## Lock flow: schedule trigger

Schedule-based blocking happens in the monitor extension, not the main app.

```
[main app, setup time]
FlowEngine.scheduleDeviceActivity(for: flow)
        │
        ├── Write ScheduledFlowMeta to App Group
        ├── Write flowAppSelection_<UUID> to App Group
        └── DeviceActivityCenter.startMonitoring(
                activity: "screeny.flow.<uuid>",
                schedule: DeviceActivitySchedule(
                    intervalStart: startComponents,
                    intervalEnd: endComponents,
                    repeats: true,
                    warningTime: nil
                )
            )

[monitor extension, at schedule window start]
DeviceActivityMonitorExtension.intervalDidStart("screeny.flow.<uuid>")
        │
        ├── Read ScheduledFlowMeta from App Group
        ├── Verify isInWindow() (guards against stale callbacks)
        ├── buildUnionShield() — union of all in-window schedules
        └── ManagedSettingsStore("screenyScheduleRestrictions").shieldSettings = ...
```

**Union at scale:** The monitor doesn't just apply one flow's shield — it reads all `scheduledFlowMetas`, checks which are in-window, and applies their union. This means 3 simultaneous schedule flows produce one shield that blocks the sum of all three flows' apps.

---

## Lock flow: usage limit trigger

Usage limits use `DeviceActivityEvent` thresholds within the schedule activity.

```
[main app, setup time]
FlowEngine.reconcileStats() (which calls the limit arm path)
        │
        └── DeviceActivityCenter.startMonitoring(
                events: [DeviceActivityEvent(
                    applications: flow.selection,
                    threshold: DateComponents(minute: limitMinutes),
                    includesPastActivity: true
                )]
            )

[monitor extension, when usage crosses the threshold]
DeviceActivityMonitorExtension.eventDidReachThreshold(
        "screeny.flow.<uuid>.<limit>min"
    )
        │
        ├── Set usageLimitTriggered_<UUID> = true in App Group
        ├── buildUnionShield() — adds this flow to the shield
        └── ManagedSettingsStore("screenyScheduleRestrictions").shieldSettings = ...
```

**The 80% warning:** At 80% of the limit threshold, a separate `DeviceActivityEvent` fires `eventDidReachThreshold` with the ".warn80" suffix. The monitor extension schedules a local push notification: "X minutes left today."

---

## Unlock flow

Unlock routes through `CanvasViewModel.unlock(flow:relockAfterMinutes:)`.

```
CanvasViewModel.unlock(flow, relockAfterMinutes: nil or N)
        │
        ├── Determine what is blocking the flow:
        │   ├── isManualBlock? → release from "screenyRestrictions"
        │   ├── isScheduleBlock? → releaseScheduleBlock (rebuild schedule shield minus this flow)
        │   └── isLimitBlock? → releaseUsageLimitBlock (rebuild limit shield minus this flow)
        │
        ├── If relockAfterMinutes != nil:
        │   └── FlowEngine.scheduleRelock(flow, afterMinutes: N)
        │           ├── Write TimedRelockEntry to App Group
        │           ├── Register "screeny.relock.<uuid>" one-shot DeviceActivity
        │           └── Arm relockTimer (in-process fallback)
        │
        └── Write UnlockLedgerEntry to App Group
```

**Allow-only pierce:** When an allow-only flow covers some block-mode flow apps, unlocking the block-mode flow removes those specific apps from the allow-only flow's blanket via `unlockedAppExceptions`. The blanket remains; only the pierced apps become accessible.

---

## Unlock invariant (CRITICAL)

From `CLAUDE.md`:

> Any change to unlock, lock, or the unlock ceremony MUST behave identically across ALL trigger paths — QR scan, NFC scan, and manual — and across every surface: Scan tab, flow detail page, folder detail page.

The predicate `CanvasViewModel.hasActiveRuleBlock(_:)` decides whether an unlock should show the timed-unlock wheel. It checks the flow's *configured rules* (a configured daily limit OR an active schedule window while blocked), NOT the transient `usageLimitTriggered_<uuid>` App Group flag. The flag is cleared on the first unlock of the day; the configured rule is never cleared unless the user removes it.

If you ever need to change unlock behavior, change `hasActiveRuleBlock` once, not at the call sites.

---

## Relock: the two-path architecture

Relocks after a timed unlock must fire even if the app is killed. Screeny uses two parallel mechanisms:

**Path 1: In-process Timer (fast, fragile)**
```swift
private func armRelockTimer() {
    // Finds the soonest pending TimedRelockEntry
    // Sets a Timer on RunLoop.main with mode .common
    // Timer fires → processRelocks(flows:)
}
```

**Path 2: DeviceActivity one-shot (reliable, requires slot)**
```swift
private func registerRelockActivity(for flow: Flow, at relockDate: Date) {
    // Registers "screeny.relock.<uuid>" with a one-time schedule ending at relockDate
    // Monitor extension's intervalDidEnd handles this:
    //   → reads TimedRelockEntry from App Group
    //   → re-applies blocked sources (wasManual/wasSchedule/wasLimit)
    //   → writes UnlockLedgerEntry(kind: .relock)
}
```

The in-process timer is the normal path. The DeviceActivity one-shot is the background reliability guarantee — it fires `intervalDidEnd` in the monitor extension even if the app is killed. Whichever fires first wins; the second finds no pending entry and no-ops (the "first consumer wins" pattern).

**RunLoop mode fix:** The timer uses `.common` mode, not `.default`. A `.default` timer never fires while the user is scrolling, which caused visible relock delays that confused users expecting their lock screen to appear exactly when the countdown ended.

---

## Schedule reconciliation: the registration lifecycle

```
reconcileSchedules(flows: [Flow])
        │
        ├── For each enabled flow with a schedule:
        │   ├── If not already registered: scheduleDeviceActivity(for: flow)
        │   └── If already registered but schedule changed: removeSchedule + re-add
        │
        └── For each registered activity without a matching flow:
            └── DeviceActivityCenter.stopMonitoring(activity)
```

`fetchRegisteredActivities()` reads the current set of registered `DeviceActivityName` values with a 3-second timeout (the `DeviceActivityCenter.activities` call can wedge if the daemon is unresponsive — this is the watchdog introduced in TF3).

---

## Activity budget: slot allocation

```swift
static let activityCeiling = 20
static let activityHeadroom = 2
static var usableActivitySlots: Int { 18 }

// Priority order for remaining 18 slots:
// 1. Relocks (timedRelockEntries.count)
// 2. Per-flow limits (flows with hasDailyLimit: 1 slot each)
// 3. Per-flow schedules (1 slot each)
// 4. Temporary release (0 or 1)
// 5. Daily heartbeat (always 1)
// 6. Coach (2 slots if coachMayArm returns true)
// 7. Stats (1 slot if statsMayArm returns true)
```

`coachMayArm()` and `statsMayArm()` compute the core need and return false if adding their slots would exceed 18. A user with 8 flows all having schedules + limits could exhaust the budget entirely, leaving no slots for coach or stats.

---

## The daily heartbeat

One DeviceActivity slot is always reserved for `"screeny.heartbeat"` — a daily schedule that fires `intervalDidStart` once per day at midnight. The monitor uses this callback to:

1. Reset `statsDailyTotal` and `statsDaily_<UUID>` to 0
2. Stamp `statsLiveDays` for the new day
3. Run `performDailySelfHeal()` — rebuilds the schedule shield union in case any in-flight relock expired overnight

This is why stats totals correctly roll over at midnight even if the app was never opened.

---

## Allow-only pierce: the complementary exception system

When an allow-only flow (blanket) is active, it blocks everything except its allowed apps. If a user unlocks a block-mode flow whose apps happen to be *outside* the allow-only allowlist, those apps would still be blocked by the blanket.

The pierce system punches specific apps out of the blanket:

```
User unlocks block-mode flow (TikTok) while allow-only blanket is active:
        │
        ├── FlowEngine identifies which apps are covered by the blanket
        │   (covered = flow.selection ∖ blanket.allowlist)
        │
        ├── Writes covered apps to unlockedAppExceptions (App Group)
        │
        └── Rebuilds blanket shield:
            allowlist = original.allowlist ∪ exceptions

When blanket re-activates (schedule start or new manual lock):
        └── Consumes exceptions OUTSIDE its allowlist (complement consume)
            so the pierce hole doesn't persist into the next session
```

---

## Hardcore mode

When `flow.hardcoreMode == true`:

1. The unlock ceremony refuses all except the exact scan token (`flow.triggerToken`)
2. Manual tap-to-unlock is disabled on the detail page
3. Emergency breaks (3 per 4-week window) are the only non-scan escape
4. The breaker wheel never shows (no timed unlock option)

Hardcore mode is the "no willpower escape hatch" design: a user who wants genuine friction puts their NFC tag somewhere physical (on their desk, on the door). To unlock, they must physically walk to the tag.

---

## Emergency break system

`EmergencyBreakManager` maintains a pool of 3 emergency breaks per 4-week window, stored in `SharedDefaults`. When a break is used:

1. The break counter is decremented
2. All manual blocks are released (full unlock)
3. A "break used" entry is written to the unlock ledger
4. The BingeBrain evaluates whether to escalate the breather tier next time

Breaks reset after 4 weeks from the first break used. This is not a calendar month — it is a 28-day rolling window.
