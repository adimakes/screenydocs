# Chapter 1 — Apple Screen Time API Constraints

Understanding what Apple's API *cannot* do is the most important chapter in this book. Every unusual design decision in Screeny — the tick ladder, the App Group IPC, the four-process split, the stats inaccuracy — traces back to a wall in Apple's Screen Time framework.

---

## The three framework families

Screen Time functionality is spread across three distinct frameworks, each with different capabilities and sandboxing rules.

### FamilyControls
**What it does:** Authentication and entitlement gateway.  
**Key type:** `AuthorizationCenter.shared.requestAuthorization(for: .individual)` — the permission prompt the user sees on first launch.  
**Restriction:** The app must hold the `com.apple.developer.family-controls` entitlement, which requires Apple's explicit approval for distribution. Development builds use the Development variant; the App Store requires the separate Production entitlement (days-to-weeks approval time). Without this entitlement the app is completely non-functional.  
**Apple docs:** https://developer.apple.com/documentation/familycontrols

### ManagedSettings
**What it does:** Apply shields (blocks) to the device — the actual enforcement layer.  
**Key type:** `ManagedSettingsStore` — a named store that holds shield state. Multiple stores can coexist; last-writer-wins within a store, but stores compose.  
**Critical restriction:** A store's blocks are applied *by process name*. If the same process writes to the store twice, the second write replaces the first — not addends. This means a single extension can only maintain one coherent state per store.  
**Screeny's stores:**
- `"screenyRestrictions"` — owned by the main app (manual locks)
- `"screenyScheduleRestrictions"` — owned by the monitor extension (schedule + limit + coach + stats blocks)

**Apple docs:** https://developer.apple.com/documentation/managedsettings

### DeviceActivity
**What it does:** Background scheduling and usage-threshold callbacks.  
**Key types:**
- `DeviceActivityCenter` — register/remove activities
- `DeviceActivitySchedule` — a recurring window (start time → end time, repeating weekly)
- `DeviceActivityEvent` — a usage threshold within a schedule window
- `DeviceActivityMonitor` — the extension class that receives callbacks

**Apple docs:** https://developer.apple.com/documentation/deviceactivity

---

## Hard limits: the 20-activity ceiling

`DeviceActivityCenter` enforces a hard ceiling of **20 simultaneously registered activities**. Exceeding this limit causes registration to silently fail — the activity is not added and no error is thrown on older iOS versions (iOS 17+ surfaces a thrown error). This is **not documented** in Apple's official API reference but has been confirmed empirically.

Screeny allocates the 20 slots as follows:

```
Total ceiling:                       20
Safety headroom (activityHeadroom):   2
Usable slots (usableActivitySlots):  18

Slot allocation priority (highest → lowest):
  1. Relock one-shots          (per pending re-lock, from timed unlocks)
  2. Daily usage-limit events  (1 per flow with a limit, for the threshold ladder)
  3. Schedule windows          (1 per flow with a schedule)
  4. Temporary release         (1 while a breather/release is active)
  5. Daily heartbeat           (1, always — used for stats self-heal)
  6. Coach pacing              (1, if budget allows — the anti-binge ladder)
  7. Stats tick ladder         (1 activity with up to 38 events, if budget allows)
```

When slots run out, lower-priority features are *not armed*. This means a user with many flows can silently lose stats sampling or coach pacing. The budget check is in `FlowEngine.coachMayArm()` and `FlowEngine.statsMayArm()`.

---

## Hard limits: event count per activity

Each registered `DeviceActivitySchedule` can hold an arbitrary number of `DeviceActivityEvent` objects, but iOS has an **undocumented practical ceiling** around 200-400 events per activity. The exact value is device- and iOS-version-dependent.

Screeny's stats ladder uses:
- Union ladder: 38 events (5/15/30... steps up to 16h)
- Per-flow ladder: 15 events × up to 16 flows = 240 events
- Total possible: **278 events in one activity**

If iOS silently truncates events, higher thresholds never fire and usage is under-reported. This has been observed on some devices: the sampler plateaus at a low tick value even on heavy-use days. **Definitive device testing is required** — check Console for `stats tick — statsDailyTotal = <N>min today` and confirm the highest N matches real usage.

---

## The read problem: no usage API

This is the most consequential restriction in the entire system.

**There is no API that lets the main app read how many minutes a specific app was used today.**

The three things Apple offers instead:

| What Apple offers | What it actually gives you | Screeny's response |
|---|---|---|
| `DeviceActivityReport` extension | A sandboxed SwiftUI view that can render usage data, but **cannot pass any data out** to the main app | Used for the usage card (home screen total) only |
| `DeviceActivityEvent` threshold callbacks | A callback fires when usage *crosses* a threshold (e.g. "Instagram crossed 30 minutes") | The tick ladder — register many thresholds, count crossings |
| `ManagedSettings` usage-limit blocks | Trigger a block when usage hits a limit, fire `intervalDidEnd` | Used for actual blocking, not measurement |

The consequence: **Screeny's statistics are reconstructed from which thresholds fired, not from direct measurement.** A stored value represents the highest tick crossed. The true value lies in `[tick, nextTick)`, introducing a quantization error of up to half a ladder step.

---

## The includesPastActivity bug

`DeviceActivitySchedule` has a property `includesPastActivity: Bool`. When `true`, iOS counts usage from *before* the schedule was registered — including usage on other devices synced via iCloud (Mac, iPad, other iPhone). This was intended for "catch up on missed time" scenarios but creates a severe bug in Screeny:

- User uses Instagram on their Mac for 2h
- Screeny is installed on iPhone with a 30-min Instagram limit
- iOS evaluates the iCloud-synced Mac usage against the limit
- The block fires *immediately* on iPhone even though the user hasn't opened Instagram on their phone at all

Screeny's current stats ladder uses `includesPastActivity: true` because it needs to catch usage from before the current schedule window started (the schedule repeats daily; without this, a user who opens an app at 11:58pm would only get 2 minutes counted before the midnight reset). This is a known trade-off with no clean resolution using the current API.

**Apple docs (schedule):** https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule

---

## Token opacity: ApplicationToken is a black box

`ApplicationToken` is the only handle the Screen Time API gives you for a specific app. It is intentionally opaque:

- Cannot be converted to a bundle ID
- `Application(token:).localizedDisplayName` returns `nil` under individual authorization (works under parental controls only)
- Cannot be serialized to a stable string — the token encoding may change across iOS versions

**What Screeny does about this:**
1. App names are stored as strings at creation time if the app is in the catalog (pre-known apps like Instagram, TikTok)
2. The `ShieldConfigurationExtension` receives the *resolved* display name and harvests it into the App Group (`"harvestedAppNames"` dict) on first shield show
3. For unresolved tokens the UI falls back to `Label(token)` — a system-rendered view that shows the real name but cannot be styled with custom fonts

This is why some app names in Screeny appear in a different font from the rest of the UI.

**Technical reference:** https://developer.apple.com/documentation/familycontrols/applicationtoken

---

## The sandboxing wall: extensions cannot write to App Group (ActivityReport)

The `DeviceActivityReport` extension runs under a *stronger* sandbox than the DeviceMonitor extension. It can read Screen Time data for display but **cannot write anything to the App Group**, cannot call network APIs, and cannot communicate with the main app in any way.

This means the report extension can render a chart of your usage history, but it *cannot* tell the main app "today's total is 4h 30m". The main app will never receive that number through the report extension.

This is why Screeny's stats architecture went through three generations:
1. **Gen 1:** Extension draws charts. App has no numbers. Working, but no interactive features.
2. **Gen 2:** Extension draws charts + tries to write to App Group. SANDBOX DENIED on real devices (works in simulator only).
3. **Gen 3 (current):** App reads its own tick-ladder history. Extension draws only the legacy usage card on home screen. All stats computation happens in the main app.

---

## Shield rendering: device-only

Shields (the blocking screen overlay) never render in the iOS Simulator. The simulator ignores `ManagedSettingsStore` and `ShieldSettings` entirely. This means:

- Custom shield UI (`ScreenyShieldConfig`) can only be tested on a physical device
- Extension OOM kills under shield load can only be reproduced on device
- The shield ghost copy (personalized lines like "Boo. Just me.") requires device testing for every text change

---

## Summary table: what each process can do

| Capability | Main app | DeviceMonitor ext | ShieldConfig ext | ActivityReport ext |
|---|---|---|---|---|
| Read Screen Time usage | NO | NO | NO | YES (sandboxed view only) |
| Write to App Group | YES | YES | YES | **NO** |
| Apply shields (ManagedSettingsStore) | YES | YES | NO | NO |
| Register DeviceActivity schedules | YES | NO | NO | NO |
| Receive schedule callbacks | NO | YES | NO | NO |
| Resolve ApplicationToken names | partial¹ | NO | YES (full) | YES (full) |
| Network access | YES | NO | NO | NO |
| SwiftData access | YES | NO | NO | NO |
| Touch events from user | YES | NO | NO | **NO** |

¹ Partial: catalog apps have stored names; picker apps require shield harvest.

---

## Apple documentation links (complete list)

- Family Controls framework: https://developer.apple.com/documentation/familycontrols  
- ManagedSettings framework: https://developer.apple.com/documentation/managedsettings  
- DeviceActivity framework: https://developer.apple.com/documentation/deviceactivity  
- DeviceActivityMonitor: https://developer.apple.com/documentation/deviceactivity/deviceactivitymonitor  
- DeviceActivityReport: https://developer.apple.com/documentation/deviceactivity/deviceactivityreport  
- DeviceActivityCenter: https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter  
- ShieldConfiguration: https://developer.apple.com/documentation/managedsettings/shieldconfiguration  
- ApplicationToken: https://developer.apple.com/documentation/familycontrols/applicationtoken  
- FamilyActivityPicker: https://developer.apple.com/documentation/familycontrols/familyactivitypicker  
- Screen Time entitlement request: https://developer.apple.com/contact/request/family-controls-distribution  
