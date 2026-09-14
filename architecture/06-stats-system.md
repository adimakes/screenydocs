# Chapter 6 — Statistics System

The statistics system is the most technically constrained part of Screeny. This chapter explains the tick-ladder proxy architecture, the five-cause accuracy problem discovered in build 23/24, the v4 fix, and what remains fundamentally limited.

---

## The core problem: no direct usage read API

As covered in Chapter 1, there is no Apple API that returns "app X was used for N minutes today." The statistics system is a workaround that reconstructs usage from *threshold-crossing events*.

---

## Tick ladder: how it works

A tick ladder is a set of `DeviceActivityEvent` objects, each with a different usage threshold. When usage crosses a threshold, the monitor extension's `eventDidReachThreshold` fires and records the highest tick seen.

**Example (simplified ladder):**
```
Register events: st_5min, st_15min, st_30min, st_60min, st_90min
(registered under the "screeny.stats" DeviceActivitySchedule)

At 12 minutes of usage: st_5min fires  → statsDailyTotal = max(prev, 5)
At 18 minutes:          st_15min fires → statsDailyTotal = max(prev, 15)
At 37 minutes:          st_30min fires → statsDailyTotal = max(prev, 30)
...
```

The `max()` write is important: it means re-arms (after an unlock) never go backward. If the user was at 30 minutes, unlocked and used more, and now crosses 60 minutes, the stored value goes 30 → 60, never backward.

---

## V4 ladder (current, build 24)

The ladder was revised to v4 after the accuracy audit in build 23/24.

### Union ladder (all block-mode flows combined)
```
Events: 38 total
Ceiling: 16 hours (960 minutes)
Steps: 5/10/15/20/25/30/40/50/60/70/80/90/100/110/120/150/180/210/240/270/
       300/330/360/390/420/450/480/510/540/570/600/630/660/690/720/780/840/900/960
Activity: "screeny.stats"
App Group key: statsDailyTotal (today), statsHistory["YYYY-MM-DD"] (history)
```

### Per-flow ladder (one per blocked flow, up to 16 flows)
```
Events: 15 per flow
Ceiling: 8 hours (480 minutes)
Steps: 5/15/30/60/90/120/150/180/210/240/270/300/360/420/480
Activity: "screeny.stats" (same activity, different event names)
App Group key: statsDaily_<UUID> (today), statsFlowHistory_<UUID>["YYYY-MM-DD"] (history)
```

### Ladder version
`FlowEngine.statsSignature` returns `"v4|<union-event-names>"`. This string is written to the App Group (`statsSignature`). The monitor extension reads it on first arm. If the signature differs from the currently registered one, it re-registers the activity with `includesPastActivity: true` (lossless catch-up). The "v4|" prefix is enough to detect any ladder change.

---

## The five-cause accuracy problem (found build 23, fixed build 24)

A device showed "1h average" in Screeny while iOS Settings showed "6h 50m". Investigation found five independent causes:

### Cause 1: Phantom zeros (the biggest factor)

**Problem:** `ScreenyStats.dailyValues` treated *every day* between `trackingStart` and today with no history entry as a hard **0 minutes**. Days where the sampler was never running (cold re-arm, OOM kill, iOS dropped the registration, `statsMayArm` returned false) were averaged in as zeros.

**Example:** 6 real days at 6h30m average inside a 30-day window → average read as **1h 19m** (6×390 / 30 = 78 min).

**Fix:** `statsLiveDays` — a new App Group key holding a `[String]` array of day keys where the sampler was confirmed active. A day is added to `statsLiveDays`:
- By the monitor on `intervalDidStart` for the stats activity (proof the sampler armed)
- By the monitor on every tick
- By the main app on every confirmed re-arm (`reconcileStats`)

A day with no entry in `statsLiveDays` and no tick history is **unknown** (rendered as a gap), not zero. Averages now divide only by the count of live days.

### Cause 2: Quantization bias (downward)

**Problem:** A stored tick value represents the *highest threshold crossed*. Truth lies in `[tick, nextTick)`. Reporting the tick value directly biased every number down by half a ladder step.

**Example:** At 55 minutes of usage, the 30-minute tick has fired but the 60-minute tick hasn't. Stored value = 30. Reported to user = 30. True value ≈ 55. Error = -25 min.

**Fix:** `ScreenyStats.estimate(tick:ladder:isToday:)` applies the midpoint correction:
- **Closed day (not today):** report `(tick + nextTick) / 2` — the midpoint. Mean absolute error reduced from 30.5 min to 9.8 min per day.
- **Today (still accumulating):** report the raw tick. Must never claim time not yet spent.
- **At ceiling:** report the ceiling value directly. No upper bound is known, so no midpoint can be computed.

### Cause 3: Ladder ceilings clipped real days

**Problem:** V3 union ladder ceiling was 720 minutes (12h). V3 per-flow ceiling was 300 minutes (5h). A 6h50m flow day read as exactly **5h flat** — capped.

**Fix:** V4 union ceiling raised to 960 minutes (16h). V4 per-flow ceiling raised to 480 minutes (8h).

### Cause 4: No "today" number anywhere

**Problem:** Every figure on the Stats tab was a per-day *average*. Nothing was directly comparable to iOS Settings' today total. Users were comparing apples (average) to oranges (today's actual).

**Fix:** `StatsScope.todayMinutes` property + a `"Today X so far"` line shown under the date range on the current page (hidden while scrubbing to avoid confusion). This is the only raw today-total number on the tab.

### Cause 5: Scope difference (by design, not a bug)

Screeny's union stats cover **block-mode flow apps only**. Allow-only flows are excluded. iOS Settings shows the *whole device*. A user who spends 3h in apps not covered by any Screeny flow will see Screeny show a lower total.

This is intentional — Screeny is "how much time am I spending in the apps I'm trying to limit" not "how much screen time total." This must be communicated clearly when numbers look low.

---

## Stats data flow (build 24)

```
[Monitor extension]
  intervalDidStart("screeny.stats")
      → stamp statsLiveDays[today]
  eventDidReachThreshold("st_<N>min")
      → max()-write statsDailyTotal
      → stamp statsLiveDays[today]
  eventDidReachThreshold("sf_<uuid>_<N>min")
      → max()-write statsDaily_<UUID>
  intervalDidStart("screeny.heartbeat")
      → rotate statsDailyTotal → statsHistory[yesterday]
      → rotate statsDaily_<UUID> → statsFlowHistory_<UUID>[yesterday]
      → reset statsDailyTotal = 0

[Main app, StatsHistoryWatcher]
  KVO on App Group → detects changes to statsDailyTotal, statsHistory, statsLiveDays
  → triggers StatsTabView rebuild

[StatsTabView]
  reads StatsHistory (days + ladder version they were sampled on)
  calls StatsChartPage.build(scope:range:pageOffset:)
  renders chart, trend rows, today line
```

---

## StatsHistory: the ladder-version bundle

Before v4, the stats history was a bare `[String: Int]` dictionary. The problem: if the ladder changes (v3 → v4), old tick values can't be correctly decoded against the new ladder. A stored value of "300" on v3's 5h ceiling means "at the ceiling" but on v4's 8h ceiling means "exactly 5h, not at ceiling."

`StatsHistory` bundles the tick dictionary with the ladder definition that produced it:

```swift
struct StatsHistory: Codable {
    var days: [String: Int]          // "YYYY-MM-DD" → highest tick seen
    var ladderVersion: String        // "v4|..." — the statsSignature when this history was recorded
    var ladder: [Int]                // the actual tick values, for midpoint computation
}
```

When reading history, `estimate(tick:ladder:isToday:)` uses the *stored* ladder (not the current one) to compute the midpoint. This prevents new ladder versions from invalidating old data.

---

## Stats chart: StatsChartPage

`StatsChartPage.build(scope:range:pageOffset:)` is the main computation entry point.

```swift
struct StatsChartPage {
    var slots: [ChartSlot]           // one per day/week/month in the window
    var average: Double              // average across live days (midpoint-corrected)
    var previousAverage: Double      // previous window's average (for % change)
    var trend: StatsTrendDirection   // .up / .down / .flat
    var canGoBack: Bool              // are there tracked days before this window?
    var todayMinutes: Double?        // raw today total (nil if today not in window)
}
```

The rolling "usual" band is computed as: mean ± 0.8σ (minimum a few minutes) centered on the current window's average. The band is rendered as an amber fill at 16% opacity.

---

## Gaps vs zeros: chart rendering

Unknown days (in `statsLiveDays` but no history entry, or not in `statsLiveDays`) are rendered as chart gaps — the polyline bridges them with a straight segment, and no dot appears. This is the honest representation: "we don't know what happened on that day."

Zero days (in `statsLiveDays` AND have a 0 history entry) are rendered as dots at y=0. This is genuinely "the apps were not used at all."

---

## What still cannot be solved

Even with all v4 fixes, three limitations are permanent given the current API:

**1. Minimum granularity of 5 minutes.** The smallest `DeviceActivityEvent` threshold is `DateComponents(minute: 1)`. Screeny uses 5 minutes as the minimum to avoid exhausting the event budget. Usage under 5 minutes is reported as 0.

**2. Pre-install history is gone.** The tick-ladder approach only records data from the day Screeny was installed and armed. The ActivityReport extension *could* show pre-install data (it reads from the OS directly), but it cannot share those numbers with the main app. The decision was made in build 20 to accept this trade-off in exchange for touch interactivity.

**3. iCloud multi-device inflation via includesPastActivity.** Setting `includesPastActivity: true` — necessary for daily continuity — means Mac/iPad usage counts toward the phone's stats. There is no API to filter by device. This means Screeny's numbers can exceed iPhone-only usage if the user heavily uses the same apps on other devices.

---

## Demo seed (simulator / dummy mode)

When running in dummy mode (`screenyDummyMode = true`), `ScreenyStatsStore` seeds 124 days of synthetic history with:
- Values snapped to the v4 ladder grid (not smooth curves — realistic quantization)
- `statsLiveDays` populated for all 124 days (no phantom zeros)
- Today's value set to simulate a partial day

This gives a realistic simulator experience for UI development. The seed is never run on non-dummy builds.
