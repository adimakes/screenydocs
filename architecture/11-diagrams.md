# Chapter 11 — Diagrams Reference

All system diagrams in one place. Every diagram is rendered from the Mermaid blocks below — open this file in any Mermaid-aware renderer (GitHub, Obsidian, VS Code + Mermaid preview) to see them visually.

---

## Diagram 1 — Four-process system architecture

```mermaid
graph TD
  subgraph Main["screeny (main app)"]
    APP["SwiftData\nFlowEngine\nCanvasViewModel"]
  end

  subgraph AG["App Group: group.com.adityabhatia.screeny"]
    AG_BLOCKING["activeBlockEntries\nscheduledFlowMetas\nflowAppSelection_&lt;UUID&gt;"]
    AG_STATS["statsDailyTotal\nstatsHistory\nstatsLiveDays"]
    AG_MIRRORS["screenyUserName\nscreenyLanguage\nharvestedAppNames"]
    AG_RELOCK["timedRelockEntries\nunlockLedger"]
  end

  subgraph MON["ScreenyDeviceMonitor (extension)"]
    MON_CB["intervalDidStart\neventDidReachThreshold\nintervalDidEnd"]
  end

  subgraph SHIELD["ScreenyShieldConfig (extension)"]
    SHIELD_DRAW["draws ghost\nblock screen"]
  end

  subgraph REPORT["ScreenyActivityReport (extension)"]
    REPORT_VIEW["renders usage view\nsandboxed — NO writes"]
  end

  subgraph DAC["DeviceActivityCenter (iOS)"]
    DAC_REG["activities\n(20-slot ceiling)"]
  end

  subgraph MSS["ManagedSettings (iOS enforcement)"]
    MSS_MANUAL["screenyRestrictions\n(manual locks — main app)"]
    MSS_SCHED["screenyScheduleRestrictions\n(schedule + limit + coach + stats — monitor ext)"]
    MSS_UNION["iOS applies UNION of all stores"]
  end

  APP -->|"writes schedules,\nselections, relocks"| AG_BLOCKING
  APP -->|"writes tracking start,\nsignature, live days"| AG_STATS
  APP -->|"writes userName,\nlanguage"| AG_MIRRORS
  APP -->|"writes TimedRelockEntries"| AG_RELOCK

  APP -->|"startMonitoring()\nstopMonitoring()"| DAC_REG
  DAC_REG -->|"callbacks delivered"| MON_CB

  MON_CB -->|"reads schedules,\nselections"| AG_BLOCKING
  MON_CB -->|"max()-writes ticks,\nstamps liveDays"| AG_STATS
  MON_CB -->|"reads relock entries"| AG_RELOCK
  MON_CB -->|"writes schedule+limit\nshields"| MSS_SCHED

  APP -->|"writes manual\nblock shields"| MSS_MANUAL

  MSS_MANUAL -->|"union"| MSS_UNION
  MSS_SCHED -->|"union"| MSS_UNION

  SHIELD_DRAW -->|"reads userName,\nlanguage"| AG_MIRRORS
  SHIELD_DRAW -->|"writes harvestedAppNames\n(app name → token map)"| AG_MIRRORS

  APP -->|"reads harvestedAppNames\non next launch"| AG_MIRRORS
  APP -->|"KVO: detects tick\nchanges for live chart"| AG_STATS

  REPORT_VIEW -->|"reads Screen Time\nfrom OS (sandboxed)"| REPORT_VIEW

  style AG fill:#2a2a2a,stroke:#888,color:#eee
  style MSS_UNION fill:#8b0000,stroke:#f00,color:#fff
  style REPORT_VIEW fill:#1a3a1a,stroke:#555,color:#aaa
```

---

## Diagram 2 — Flow data model

```mermaid
classDiagram
  class Flow {
    +UUID id
    +String name
    +Date createdAt
    +Bool isEnabled
    +String tileKindRaw
    +String blockingModeRaw
    +String triggerType
    +Data? triggerData
    +Data? blockingData
    +Data? unblockData
    +Data? selectedAppsData
    +Int? scheduleStartHour
    +Int? scheduleEndHour
    +Int? weekendLimitMinutes
    +Bool hardcoreMode
    +Bool warn80Enabled
    +Int schemaVersion
    +Bool startBlocked
    +UUID? keyID
    +Bool hasDailyLimit
    +Bool isZeroLimitToday
    +Bool isCurrentlyInScheduleWindow
    +String displayName
  }

  class Key {
    +UUID id
    +String name
    +String token
    +String keyType
    +Date createdAt
    +String? iconName
  }

  class WorkflowTrigger {
    +TriggerKind kind
    +String? token
    +String? label
    +Int? scheduleStartHour
    +Int? scheduleEndHour
    +Int? scheduleStartMinute
    +Int? scheduleEndMinute
    +Array~Int~? scheduleWeekdays
  }

  class BlockingStrategy {
    +ActionKind kind
    +Int? durationMinutes
    +Data? appSelectionData
    +Bool hardcoreMode
    +Int? usageLimitMinutes
  }

  class WorkflowBreaker {
    +BreakerMode mode
    +WorkflowTrigger? customTrigger
    +Int? temporaryReleaseDurationMinutes
  }

  class TriggerKind {
    <<enumeration>>
    nfc
    qr
    barcode
    schedule
    manual
    appUsageLimit
  }

  class ActionKind {
    <<enumeration>>
    block
    blockForDuration
    unblock
  }

  class BreakerMode {
    <<enumeration>>
    sameAsTrigger
    customTrigger
    manualOnly
    temporaryRelease
  }

  class FlowTileKind {
    <<enumeration>>
    singleApp
    folder
    category
  }

  class ScreenyBlockingMode {
    <<enumeration>>
    block
    allowOnly
  }

  Flow "1" --> "0..1" Key : keyID FK
  Flow o-- WorkflowTrigger : decoded from triggerData
  Flow o-- BlockingStrategy : decoded from blockingData
  Flow o-- WorkflowBreaker : decoded from unblockData
  WorkflowTrigger --> TriggerKind
  BlockingStrategy --> ActionKind
  WorkflowBreaker --> BreakerMode
  Flow --> FlowTileKind
  Flow --> ScreenyBlockingMode
```

---

## Diagram 3 — Blocking state machine

```mermaid
stateDiagram-v2
  [*] --> Unlocked

  Unlocked --> ManuallyLocked : executeFlow() / scan trigger
  Unlocked --> ScheduleLocked : intervalDidStart (monitor ext)
  Unlocked --> LimitLocked : eventDidReachThreshold (monitor ext)

  ManuallyLocked --> TimedUnlock : unlock(relockAfterMinutes=N)
  ManuallyLocked --> Unlocked : unlock(relockAfterMinutes=nil)\nor fullUnlock / emergency break
  ManuallyLocked --> TemporaryRelease : requestBreaker() — breather mode

  ScheduleLocked --> Unlocked : releaseScheduleBlock()\nor intervalDidEnd
  ScheduleLocked --> TimedUnlock : unlock(relockAfterMinutes=N)

  LimitLocked --> Unlocked : releaseUsageLimitBlock()\nor unlock(relockAfterMinutes=nil)
  LimitLocked --> TimedUnlock : unlock(relockAfterMinutes=N)

  TimedUnlock --> ManuallyLocked : relockDate reached\n(wasManual = true)
  TimedUnlock --> ScheduleLocked : relockDate reached\n(wasSchedule = true)
  TimedUnlock --> LimitLocked : relockDate reached\n(wasLimit = true)

  TemporaryRelease --> ManuallyLocked : reapplyAfterTemporaryRelease()\n(breather timer expires)

  note right of ManuallyLocked
    HARDCORE MODE:
    only exact scan token accepted.
    Manual unlock button disabled.
    Emergency breaks are the only
    non-scan escape path.
  end note

  note right of TimedUnlock
    Two parallel paths fire relock:
    1. In-process Timer (RunLoop .common)
    2. DeviceActivity one-shot (background)
    First consumer wins — second is a no-op.
  end note
```

---

## Diagram 4 — DeviceActivity slot budget (20-slot ceiling)

```mermaid
pie title DeviceActivity slot allocation (typical: 3 flows with schedules + limits)
  "Safety headroom" : 2
  "Relock one-shots (variable)" : 2
  "Per-flow daily limits" : 3
  "Per-flow schedule windows" : 5
  "Temporary release" : 1
  "Daily heartbeat" : 1
  "Coach pacing" : 2
  "Stats tick ladder" : 1
```

Priority order (highest → lowest). When slots are exhausted, lower-priority features are silently not armed:

```mermaid
graph LR
  subgraph Priority["Slot priority — highest to lowest"]
    P1["1. Relock one-shots\n(active re-locks)"]
    P2["2. Daily usage limits\n(1 per flow with limit)"]
    P3["3. Schedule windows\n(1 per scheduled flow)"]
    P4["4. Temporary release\n(breather/release active)"]
    P5["5. Daily heartbeat\n(always 1 — midnight reset)"]
    P6["6. Coach pacing\n(2 slots — if budget allows)"]
    P7["7. Stats tick ladder\n(1 activity, 38 events — if budget allows)"]
  end

  P1 --> P2 --> P3 --> P4 --> P5 --> P6 --> P7

  WARN["WARNING: A user with 8+ flows\ncan exhaust all 18 usable slots,\nsilently disabling coach + stats.\nNo UI warning currently exists."]

  P7 -. "dropped when full" .-> WARN

  style WARN fill:#5a2000,stroke:#f80,color:#ffd
```

---

## Diagram 5a — Stats tick ladder v4 (threshold structure)

```mermaid
graph LR
  subgraph Union["Union ladder — 38 events, ceiling 960 min (16h)"]
    direction LR
    T0["0 min\n(start)"]
    T5["5"]
    T10["10"]
    T15["15"]
    T20["20"]
    T25["25"]
    T30["30"]
    T40["40"]
    T60["60"]
    T90["90"]
    T120["120"]
    T180["180"]
    T240["240"]
    T300["300"]
    T360["360"]
    T480["480"]
    T600["600"]
    T720["720"]
    T840["840"]
    T960["960 (16h)\nceiling"]

    T0 --> T5 --> T10 --> T15 --> T20 --> T25 --> T30 --> T40 --> T60 --> T90 --> T120 --> T180 --> T240 --> T300 --> T360 --> T480 --> T600 --> T720 --> T840 --> T960
  end

  subgraph Reading["How stored values are read"]
    R1["stored = 30\ntrue value in [30, 40)"]
    R2["closed day:\nreport midpoint = 35 min\n(mean error ≈ 9.8 min/day)"]
    R3["today (open):\nreport raw = 30 min\n(never claim unspent time)"]
    R4["at ceiling (960):\nreport 960\n(no upper bound known)"]
  end
```

## Diagram 5b — Stats tick event sequence

```mermaid
sequenceDiagram
  participant iOS as iOS (DeviceActivity)
  participant MonExt as ScreenyDeviceMonitor
  participant AG as App Group
  participant MainApp as screeny (main app)
  participant Chart as StatsTabView

  Note over iOS,Chart: User opens Instagram — usage accumulates

  iOS->>MonExt: eventDidReachThreshold("st_5min")
  MonExt->>AG: max()-write statsDailyTotal = 5
  MonExt->>AG: append statsLiveDays["2026-09-09"]

  iOS->>MonExt: eventDidReachThreshold("st_15min")
  MonExt->>AG: max()-write statsDailyTotal = 15

  iOS->>MonExt: eventDidReachThreshold("st_30min")
  MonExt->>AG: max()-write statsDailyTotal = 30
  MonExt->>AG: append statsLiveDays["2026-09-09"] (idempotent)

  AG-->>MainApp: KVO fires (UserDefaults change notification)
  MainApp->>Chart: rebuild() — recompute StatsChartPage

  Note over Chart: Chart morphs live — today dot moves up

  Note over iOS,Chart: Midnight heartbeat fires

  iOS->>MonExt: intervalDidStart("screeny.heartbeat")
  MonExt->>AG: rotate statsDailyTotal → statsHistory["2026-09-09"] = 30
  MonExt->>AG: reset statsDailyTotal = 0
  MonExt->>AG: stamp statsLiveDays["2026-09-10"]
```

---

## Diagram 6 — IPC data flows (complete sequence)

```mermaid
sequenceDiagram
  participant MainApp as screeny (main app)
  participant AG as App Group
  participant DAC as DeviceActivityCenter
  participant MonExt as ScreenyDeviceMonitor
  participant ShieldExt as ScreenyShieldConfig
  participant ReportExt as ScreenyActivityReport

  rect rgb(30, 50, 30)
    Note over MainApp,MonExt: 1. Schedule setup
    MainApp->>AG: write scheduledFlowMetas[flowID]
    MainApp->>AG: write flowAppSelection_<UUID>
    MainApp->>DAC: startMonitoring("screeny.flow.<uuid>", schedule)
    Note over DAC: activity registered (uses 1 slot)
  end

  rect rgb(30, 30, 60)
    Note over DAC,MonExt: 2. Schedule window fires
    DAC->>MonExt: intervalDidStart("screeny.flow.<uuid>")
    MonExt->>AG: read scheduledFlowMetas (all flows)
    MonExt->>AG: read flowAppSelection_<UUID> (each in-window flow)
    MonExt->>MonExt: buildUnionShield() — union of all in-window flows
    MonExt->>MonExt: ManagedSettingsStore("screenyScheduleRestrictions").shieldSettings = ...
    Note over MonExt: block applied to device
  end

  rect rgb(50, 30, 30)
    Note over MonExt,MainApp: 3. Stats tick
    DAC->>MonExt: eventDidReachThreshold("st_30min")
    MonExt->>AG: max()-write statsDailyTotal = 30
    MonExt->>AG: append statsLiveDays[today]
    AG-->>MainApp: KVO fires
    MainApp->>MainApp: StatsTabView.rebuild()
  end

  rect rgb(50, 40, 10)
    Note over ShieldExt,MainApp: 4. App name harvest
    ShieldExt->>AG: read harvestedAppNames["<token-key>"]
    Note over ShieldExt: key absent — name unknown
    ShieldExt->>ShieldExt: Application(token:).localizedDisplayName → "Instagram"
    ShieldExt->>AG: write harvestedAppNames["<token-key>"] = "Instagram"
    Note over MainApp: next launch
    MainApp->>AG: read harvestedAppNames
    MainApp->>MainApp: ScreenyAppNames cache updated
  end

  rect rgb(20, 40, 50)
    Note over MainApp,MonExt: 5. Timed relock
    MainApp->>AG: write TimedRelockEntry{flowID, relockDate, wasManual:true}
    MainApp->>DAC: startMonitoring("screeny.relock.<uuid>", one-shot at relockDate)
    Note over DAC: timer also armed in-process (RunLoop .common)
    DAC->>MonExt: intervalDidEnd("screeny.relock.<uuid>")
    MonExt->>AG: read TimedRelockEntry
    MonExt->>MonExt: re-apply wasManual block → ManagedSettingsStore
    MonExt->>AG: write UnlockLedgerEntry{kind: .relock}
    MonExt->>AG: delete TimedRelockEntry (consumed)
  end

  rect rgb(10, 10, 40)
    Note over ReportExt: 6. Activity Report (sandboxed)
    MainApp->>ReportExt: DeviceActivityReport view (remote render)
    ReportExt->>ReportExt: reads Screen Time data from OS
    ReportExt->>ReportExt: renders usage card SwiftUI view
    Note over ReportExt: CANNOT write to App Group\nCANNOT receive touch events
  end
```

---

## Diagram 7 — Onboarding flow (11 steps)

```mermaid
flowchart TD
  START(["App first launch\nhasOnboarded = false"]) --> S1

  S1["Step 1\nSplash\n'Hey. I'm Screeny.'\nTap anywhere to begin"]
  S1 --> S2

  S2["Step 2\nName\nAsk for screenyUserName"]
  S2 --> S2_CHECK{Name entered?}
  S2_CHECK -->|"yes"| S3
  S2_CHECK -->|"skip / empty\n(not allowed)"| S2

  S3["Step 3\nHook\nGhost talks — sets the premise\n'I'll lock the apps you choose'"]
  S3 --> S4

  S4["Step 4\nScreen Time Permission\nOpal-style popup + gradient ring"]
  S4 --> S4_CHECK{Permission granted?}
  S4_CHECK -->|"granted"| S5
  S4_CHECK -->|"denied"| S4_RETRY["Retry / explain\nloop"]
  S4_RETRY --> S4

  S5["Step 5\nPick Apps\nFamilyActivityPicker embedded inline\nCategories stripped immediately"]
  S5 --> S6

  S6["Step 6\nDaily Limit\nBigNumberPicker — minutes per day\n0 = blocked all day"]
  S6 --> S7

  S7["Step 7\nSchedule\nTime range + weekday picker"]
  S7 --> S8

  S8["Step 8\nKey Type\nScan explanation:\n'One scan locks, next unlocks'"]
  S8 --> S9

  S9["Step 9\nNotifications Permission\nPopup replica + benefit rows"]
  S9 --> S9_CHECK{Permission granted?}
  S9_CHECK -->|"granted"| S10
  S9_CHECK -->|"denied (soft fail) — no block, just fewer features"| S10

  S10["Step 10\nDone\nPersonalized: 'You're set, &lt;name&gt;.'\nScreeny logo + hovering app icons"]
  S10 --> S11

  S11["Step 11\nHold-to-Commit Ceremony\nHold 6 s to activate the first Flow\n'Starting your streak...'"]
  S11 --> END

  END(["hasOnboarded = true\nStreak = day 1\nMain shell visible"])

  style S4_RETRY fill:#5a2000,stroke:#f80,color:#ffd
  style END fill:#1a3a1a,stroke:#4a8,color:#afa
```

---

## Diagram 8 — Shield store composition

How two independent `ManagedSettingsStore` instances combine to produce the final block:

```mermaid
graph TD
  subgraph APP_STORE["screenyRestrictions\n(main app — manual locks)"]
    APP_BLOCK["blocks: Instagram, TikTok"]
  end

  subgraph MON_STORE["screenyScheduleRestrictions\n(monitor ext — schedule + limit + coach + stats)"]
    MON_BLOCK["blocks: YouTube, Reddit\n(schedule 9pm-11pm)"]
  end

  subgraph IOS["iOS ManagedSettings enforcement"]
    UNION["UNION of all stores\nInstagram ✗\nTikTok ✗\nYouTube ✗\nReddit ✗"]
  end

  APP_STORE --> UNION
  MON_STORE --> UNION

  NOTE["Unlocking from one store does NOT\nrelease a block held by the other store.\nA manual unlock during an active schedule\nstill leaves the schedule block in place."]

  UNION -. "critical gotcha" .-> NOTE

  style NOTE fill:#5a2000,stroke:#f80,color:#ffd
  style UNION fill:#1a1a3a,stroke:#88f,color:#ccf
```

---

## Diagram 9 — Stats accuracy: the five causes

```mermaid
graph TD
  SYMPTOM["Symptom: Screeny shows 1h avg\niOS Settings shows 6h 50m"]

  SYMPTOM --> C1 & C2 & C3 & C4 & C5

  C1["Cause 1: PHANTOM ZEROS\nDays with no history entry\ntreated as 0 min\n6 real days ÷ 30 window = 1h 19m avg"]
  C2["Cause 2: QUANTIZATION BIAS\nStored value = highest tick crossed\nTrue value in tick, nextTick\n30-min tick → user was at 55 min → reported 30"]
  C3["Cause 3: LADDER CEILING CLIP\nv3 per-flow ceiling was 5h\nA 6h 50m day reported as exactly 5h"]
  C4["Cause 4: NO TODAY NUMBER\nEvery figure was a per-day AVERAGE\nNothing comparable to Settings' today total"]
  C5["Cause 5: SCOPE MISMATCH\nScreeny: block-mode flows only\niOS Settings: whole phone\nBy design — not a bug"]

  C1 --> F1["Fix: statsLiveDays stamps\nUnknown days = gap, not zero\nAverages divide by live days only"]
  C2 --> F2["Fix: estimate midpoint\nclosed day → tick + nextTick / 2\ntoday → raw tick only"]
  C3 --> F3["Fix: v4 ladder\nUnion ceiling 16h\nPer-flow ceiling 8h"]
  C4 --> F4["Fix: todayMinutes field\n'Today 5h 30m so far' line\nvisible on current page"]
  C5 --> F5["Communicate clearly:\n'Block-mode flows only'"]

  style SYMPTOM fill:#5a0000,stroke:#f00,color:#fdd
  style C1 fill:#3a2000,stroke:#f80,color:#ffd
  style C2 fill:#3a2000,stroke:#f80,color:#ffd
  style C3 fill:#3a2000,stroke:#f80,color:#ffd
  style C4 fill:#3a2000,stroke:#f80,color:#ffd
  style C5 fill:#1a2a1a,stroke:#888,color:#ccc
  style F1 fill:#1a3a1a,stroke:#4a8,color:#afa
  style F2 fill:#1a3a1a,stroke:#4a8,color:#afa
  style F3 fill:#1a3a1a,stroke:#4a8,color:#afa
  style F4 fill:#1a3a1a,stroke:#4a8,color:#afa
  style F5 fill:#1a3a1a,stroke:#4a8,color:#afa
```
