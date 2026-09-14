# Chapter 8 — Known Blockers & Active Bugs

This chapter documents every known bug, limitation, and design constraint — with root causes, current status, and potential resolution paths.

---

## Blocker 1: Unreliable auto-blocking (schedules and limits)

**Symptom:** A scheduled block or usage-limit block fires on some days but not others, or fires late. Users report "I set a 9pm–11pm block and it didn't activate last night."

**Severity:** Critical — this is the primary reliability concern for the product.

### Root cause A: iOS background-app suspension

`DeviceActivityCenter` callbacks (`intervalDidStart`, `eventDidReachThreshold`) are delivered to the monitor extension, which runs as a background daemon. iOS can:
- Delay delivery by minutes when the device is in low-power mode
- Skip delivery entirely if the device hasn't been used recently (thermal throttling, low battery)
- OOM-kill the extension between the registration and the callback

When this happens, a schedule that should activate at 9pm may fire at 9:04pm, or not fire until the user opens the main app.

**No known complete fix.** Apple does not guarantee real-time delivery of DeviceActivity callbacks.

### Root cause B: The 20-activity ceiling hit silently

If a user adds enough flows that `statsMayArm` returns false and schedules also exhaust the 18-slot budget, new schedules are registered but iOS silently rejects them. The call to `DeviceActivityCenter.startMonitoring` appears to succeed but the activity is not actually registered.

**Current detection:** `FlowEngine.fetchRegisteredActivities()` reads the currently-registered set back from `DeviceActivityCenter`. If a flow's activity name is absent, the schedule failed silently. The app logs this but does not surface it to the user.

**Fix needed:** Show a warning in the UI when registered activities don't match expected. Prioritize relocks + limits > schedules > coach > stats in slot allocation (already done in the budget code).

### Root cause C: Extension OOM kill (memory pressure)

The monitor extension has ~15-30 MB of memory. If a large stats tick callback runs while device memory is constrained, the extension can be killed before writing the result. The next callback starts a fresh process with no in-memory state.

**Detection:** `extMemWorstFreeKB` in the App Group. If this is consistently below 3,000 KB, the extension is in danger.

**Mitigation:** The extension writes to the App Group on every tick (not just at the end). If it's killed mid-computation, the partial result is preserved.

### Root cause D: includesPastActivity blocks before phone limit

**Symptom:** "My 30-minute Instagram limit blocked my phone immediately after I installed Screeny."

**Root cause:** `DeviceActivityEvent` with `includesPastActivity: true` counts usage on other iCloud-synced devices (Mac, iPad) toward the phone's threshold. If the user spent 45 minutes on Instagram on their Mac today, and the phone limit is 30 minutes, the block fires the moment the event is registered.

**Current workaround:** None. Disabling `includesPastActivity` would fix premature blocking but break daily continuity (usage before midnight wouldn't count toward the new day's total until recrossed).

**Apple API request:** A `deviceScope: .thisDevice` option on `DeviceActivityEvent` would fix this completely. This should be filed as a Feedback Assistant request.

---

## Blocker 2: Stats inaccuracy vs iOS Settings

**Symptom:** "Screeny shows 1h 30m average but Settings shows I used Instagram 5 hours today."

This was fixed in build 24 for four of the five causes. See Chapter 6 for the full five-cause analysis.

**Remaining limitation:** Scope mismatch (Screeny counts block-mode flow apps only; Settings counts the whole phone). This is by design but must be clearly communicated to users when numbers look low.

**Remaining technical limitation:** `includesPastActivity: true` inflates stats with cross-device usage. Not fixable without an Apple API change.

---

## Blocker 3: Statistics detection for apps not in block-mode flows

**Symptom:** "I want to see how much time I spend in Safari, but I didn't add it as a blocked app."

**Root cause:** The tick ladder only fires for apps that are registered in the stats activity's event set. The stats activity is built from the union of block-mode flow app selections. Apps not in any block-mode flow are never sampled.

**This is a fundamental architectural limit.** Changing it would require:
1. A new stats ladder that includes all apps the user might care about
2. This would use additional DeviceActivity event slots (already tight)
3. The user would need a way to specify "track these apps even if not blocking them"

**Potential path:** A separate "Tracking" flow type that adds apps to the stats ladder without applying any shield. Estimated cost: ~1 sprint.

---

## Blocker 4: App name tokens on pre-iOS 18 devices

**Symptom:** Some flow tiles show "App" instead of the real app name.

**Root cause:** `Application(token:).localizedDisplayName` returns `nil` under individual FamilyControls authorization. It only returns names under parental controls authorization. This is a privacy design choice by Apple — the app should not be able to identify what apps the user picked.

**Current workaround:** 
1. Catalog apps (Instagram, TikTok, YouTube, etc.) have their names stored at creation time
2. Shield harvest: the `ShieldConfigurationExtension` can resolve names and stores them in the App Group. Names appear after the app is first blocked.
3. Users can manually rename flows

**Apple API request:** Even a one-way hash or a localized-name API under individual authorization would solve this.

---

## Blocker 5: FamilyActivityPicker in simulator

**Symptom:** "The app picker doesn't show real apps in the simulator."

**Root cause:** `FamilyActivityPicker` only shows real installed apps on a physical device with a real Apple ID. The simulator shows a fake app list with hardcoded names.

**Impact:** Several features cannot be tested in the simulator:
- Category rejection (the simulator never shows real category rows)
- Allow-only pierce (need real app tokens to verify exception behavior)
- Shield rendering (never shown in simulator)
- Extension OOM kills (memory profile differs greatly)

**Workaround:** Use a physical device for all feature-complete testing. The simulator is useful only for UI layout and non-Screen-Time logic.

---

## Known bug: daemon wedge at startup

**Symptom:** "The app hangs for 3-5 seconds on launch."

**Root cause:** `DeviceActivityCenter.activities` (the call that fetches currently-registered activity names) can block indefinitely if the Screen Time daemon (`mstreamd`) is wedged or slow to respond.

**Fix (build 15+):** `FlowEngine.fetchRegisteredActivities()` wraps the call in a 3-second timeout. If the call doesn't complete in time, the function returns `nil` and the engine skips the reconciliation pass for that launch.

---

## Known bug: stale usage-limit triggered flag

**Symptom:** "I unlocked my Instagram flow, used it for a while, and then it re-blocked itself even though I hadn't hit the limit again."

**Root cause (old):** The ceremony check used `usageLimitTriggered_<UUID>` (a transient flag set when the limit fires, cleared by the first unlock). On the second unlock of the day, the flag was already cleared, so `hasActiveRuleBlock` returned false, and the timed-unlock wheel didn't show. The user got a plain "unlock forever" instead of the timed wheel. But re-blocking happened because the schedule store still held the shield.

**Fix (merged to main):** `CanvasViewModel.hasActiveRuleBlock` now checks the *configured rules* (does this flow have a daily limit? Is this flow's schedule currently in-window?) rather than the transient flag. The predicate now correctly identifies "this flow has a rule that would re-block it" from first principles.

---

## Known limitation: no webhook / no automation

Currently Screeny has no HTTP API, no webhook, and no automation hooks beyond Siri Shortcuts. A power-user request is "block Instagram when I open Slack" (productivity mode trigger). There is no API mechanism for this — `DeviceActivity` schedules are time-based only, not event-based.

**Apple API request:** A new trigger type for `DeviceActivity` based on foreground app changes would enable this. Alternatively, a Shortcuts action that calls `FlowEngine.executeFlow` (already have `LockFlowIntent`) could be chained, but requires user interaction.

---

## Technical debt inventory

| Area | Issue | Severity |
|---|---|---|
| Flow schema | v1→v2 migration runs lazily on every read | Low (no perf impact observed) |
| Struct duplication | Monitor extension duplicates ~10 shared types | Medium (risk of drift) |
| Activity budget | No UI warning when budget is exhausted | High (silent failure) |
| Stats ladder | Event count (278) near undocumented iOS limit | High |
| Relock timer | RunLoop.main — not reliable during heavy UI | Low (DeviceActivity one-shot backs it up) |
| App naming | 30+ app icons show "App" on first install | Medium (UX friction) |
| Onboarding analytics | No funnel data — don't know where users drop off | Medium |
