# Chapter 10 — Roadmap & Open Work

Current state of the codebase as of build 24 (2026-09-08), pending work, and near-term priorities.

---

## Immediate: device-test gate (BLOCKING RELEASE)

Everything on `staging-build18` (build 24) is UNCOMMITTED or merged but not device-tested. Nothing goes to `main` until these pass on a physical iPhone.

### Must test on device

| Feature | What to test | Status |
|---|---|---|
| Real stats ticks | Open a blocked app, check Console for `stats tick — statsDailyTotal = <N>min today`. Verify N grows and plateaus at real usage. | PENDING |
| Stats numbers match | After 30+ min of use, compare Screeny's "today" number to iOS Settings. Should be within ±15 min. | PENDING |
| V4 re-arm | Kill and reopen the app. Verify `statsSignature` triggers a lossless re-arm with `includesPastActivity`. | PENDING |
| Schedule activation | Set a 5-minute schedule starting 1 minute from now. Verify block fires on time. | PENDING |
| Usage limit | Set a 15-min limit on any app. Use it 15 min. Verify block fires. Unlock. Verify re-lock after N minutes. | PENDING |
| Allow-only pierce | Create an only-allow flow blocking everything. Create a separate block-mode flow for one app. Unlock the block-mode flow. Verify that app is accessible while the blanket holds. | PENDING |
| Hardcore mode | Create a flow with hardcore mode. Lock it. Attempt manual unlock. Verify refused. Scan the key. Verify unlocks. | PENDING |
| Shield rendering | Lock any flow. Open a shielded app. Verify the Screeny ghost shield renders. Verify the ghost line is personalized. | PENDING |
| Extension memory | Check `extMemWorstFreeKB` after a heavy-use session. Should be above 3,000 KB. | PENDING |
| Stats ladder ceiling | Use an app for 8+ hours straight. Verify the per-flow number doesn't cap at 5h (v3 bug). | PENDING |
| DE strings | Switch to German. Verify all UI strings render correctly. | PENDING |
| Haptics on scrub | Scrub the stats chart. Verify `Haptics.selection()` fires per new slot. | PENDING |
| Relock warning push | Set a 30-min limit, unlock with timed relock (15 min). Verify a push fires ~1 min before relock. | PENDING |

---

## Near-term follow-up (agreed, not started)

### Activity budget warning UI
Show a banner or settings row when the DeviceActivity slot budget is near-exhausted. Prevents the silent failure mode where a new schedule doesn't register.

### Apple Feedback Assistant submissions
The following issues require an Apple API change to resolve. File Feedback Assistant (feedbackassistant.apple.com) tickets:
1. **`deviceScope: .thisDevice` on `DeviceActivityEvent`** — prevents cross-device usage inflation of usage limits and stats
2. **`Application(token:).localizedDisplayName` under individual auth** — allows app names without shield harvest
3. **`DeviceActivityCenter` event limit documentation** — request official documentation of the event ceiling per activity

### Stats tab: "Track without blocking" flows
A flow type that adds apps to the stats ladder without applying any shield. Enables usage tracking for apps the user doesn't want to block.

### Anti-binge: coach ladder device test
The anti-binge coach (BingeBrain + personalized breaks) has not been device-tested. Specifically:
- Does the breather tier escalate correctly after repeated unlocks?
- Does the breather timer overlay display at the right moment?
- Does the coach slot arm correctly when the budget allows?

### Spanish localization
Resume the partial Spanish strings from git history. Requires native speaker review.

### Analytics funnel
Merge the Supabase analytics branch (`analytics`, unpushed) after fixing the RLS policy. Data needed: onboarding completion rate, which step users drop off at, feature adoption (scheduled vs manual locks, stats tab engagement).

---

## Medium-term (not started, estimated)

### Widgets
Home screen widget showing today's most-used blocked app and time spent. Uses `TimelineProvider` + `DeviceActivityReport` for the number (same constraint: no direct read, extension only).

### Shortcuts automation
Expose more `AppIntents` for Shortcuts:
- "Lock everything for N minutes" (cinema mode)
- "Report today's usage" (speaks or displays the tick total)
- "Show my stats" (deep-links into the Stats tab)

### Cloud sync
Sync flow configurations across devices via CloudKit or iCloud. Currently all configuration is device-local. Requires a new CloudKit container and migration from the local SwiftData store.

### macOS companion (Catalyst or native)
Manage flows and view stats on Mac. Blocking would require Family Controls on macOS (separate entitlement). This is probably a v2 product decision.

---

## Backlog (aspirational)

- **Dynamic themes:** More color palettes beyond Furniture-dark and light-mode
- **Flow import/export:** Share a flow configuration as a QR code or deep link
- **Group coaching:** Compare usage with friends (requires server-side component)
- **Zapier/webhook integration:** "When blocked, send a Slack message" automation
- **Wear OS / watchOS:** Notifications and quick-unlock from the wrist

---

## What's on `main` vs `staging-build18`

```
main (06881a2, build 16)
├── All features through 2026-08-07
├── Category blocking rejection
├── Personalized breaks exclusion strip
├── Only-allow pierce
└── Stats tab (extension-drawn, pre-rebuild)

staging-build18 (build 24, UNCOMMITTED)
└── Everything above, PLUS:
    ├── Stats tab rebuild (app-drawn, interactive)
    ├── Stats accuracy fix (v4 ladder, phantom zeros, midpoint)
    ├── statsLiveDays liveness stamps
    ├── Today total display
    └── StatsHistory ladder-bundled struct
```

Nothing from `staging-build18` is on `main` until the device-test gate clears.
