# Chapter 7 — UI Architecture

This chapter covers navigation structure, screen hierarchy, component patterns, and the most important interaction contracts.

---

## Navigation structure

Screeny uses a tab-based navigation with 4 tabs. All tabs are always live — no lazy loading.

```
ContentView
    │
    ├── OnboardingFlowView (if !hasOnboarded)
    │
    └── MainShellView (TabView)
        ├── Home tab          (HomeWorkflowView)
        ├── Scan tab          (CameraScannerView)
        ├── Keys tab          (KeysGalleryView)
        └── Stats tab         (StatsTabView)
```

`ContentView` gates on `@AppStorage("hasOnboarded")`. `MainShellView` owns the tab selection and the `settingsTarget` state for deep-linking into Settings.

---

## Home tab

```
HomeWorkflowView
├── Streak strip            ← consecutive-day flame count
├── Headline                ← personalized greeting ("Hey. 3 Things locked.")
├── Usage card              ← DeviceActivityReport extension (today's screen time total)
├── Ghost card              ← StatsSuggestion coaching card (amber glow, deep-link CTA)
├── Flow list rows          ← FlowRowView × N (tap → detail)
└── Add flow button
```

### Flow rows

Flow rows are `Label(applicationToken)` wrapped in a custom container. The `Label` is rendered by the system in the system's own font with the real app icon and name — it cannot be styled with custom fonts. Everything else on the row (lock state badge, scheduled indicator, the tile chrome) is Screeny's own.

### Ghost card (StatsSuggestion)

The ghost card is the coaching surface. It shows one suggestion at a time, chosen by priority:
1. **Breathers off** (most urgent): encourage enabling Personalized breaks
2. **Flow limit** ≥90% spent: suggest tightening the limit
3. **No schedule but usage** ≥40 min: suggest adding a schedule
4. **Soft suggestions** (rotate daily, `day % soft.count`): praise, harsher mode, add more apps, night allow-list

The card glows amber (`amberGlow()` in `StatsTheme.swift`) and the entire card is tappable. A chevron appears when a destination exists. Tapping follows `StatsTabView.follow(_:)` which routes to:
- `.settings(target)` → opens Settings sheet pre-scrolled to a specific section
- `.flow(id)` → opens flow detail
- `.addApps(mode)` → opens app picker in the specified mode
- `.none` → no action, no chevron

---

## Flow detail (single app)

```
FlowDetailView
├── Hero (icon + name, left-aligned)
├── Lock/Unlock section
│   ├── Lock state indicator
│   ├── Unlock button (or disabled if hardcore)
│   └── Timed unlock wheel (shown when hasActiveRuleBlock)
├── Schedule section (if schedule configured)
├── Daily limit section (if limit configured)
├── Stats mini (chart + today value)
├── Breaker settings
└── Key section
```

**Timed unlock wheel:** Shows `BigNumberPicker` (5–120 min in 5-min steps) when `hasActiveRuleBlock` is true. "Unlock for N minutes" calls `CanvasViewModel.unlock(flow:relockAfterMinutes:N)`. The wheel is hidden for allow-only flows (0 = indefinite, no re-lock makes sense for a blanket).

---

## Folder detail

```
FolderDetailView
├── Aurora backdrop (blue radial wash — only allow-only folders get the blue treatment)
├── Hero (folder name, icon strip)
├── Lock/Unlock section
├── Member app list (tap to remove; minimum 1 app enforced)
└── Usage card
```

Folder unlock routes through the same `CanvasViewModel.unlock` path as single-app flows.

---

## Stats tab

```
StatsTabView
├── Headline ("6h 52m / day" + amber %)
├── "Today 5h 30m so far" line
├── StatsTrendCard (chart)
│   ├── Header (big average, verdict, date range)
│   ├── Chart (polyline, band, dots, Ø pill)
│   └── StatsRangeControls (7D / 30D / 1Y / All + page arrows)
├── StatsTrendRows ("Trends" card: 3/7/14/30-day rows)
└── FlowStatsPager (TabView, one page per block-mode flow)
    └── Per-flow page:
        ├── Ghost card (flow-specific tip)
        ├── StatsTrendCard (scoped to flow)
        └── StatsTrendRows
```

### Chart interaction

**Tap:** `SpatialTapGesture` (not `.onTapGesture` — the hold-drag sequence steals the touch before onTapGesture fires). Tap selects/deselects a slot.

**Hold-drag to scrub:** `LongPressGesture(minimumDuration: 0.15).sequenced(before: DragGesture(minimumDistance: 0))`. The 0.15s hold delay keeps vertical scrolling functional — a direct drag without the hold preamble is interpreted as a scroll by the containing `ScrollView`.

**Selected state:** dashed vertical guide, glowing dot, bar segment lit. Ø pill hidden. Header shows selected day's value + date + "Below/Above your usual" with the band range.

### Chart morphing

Range changes (7D → 30D → 1Y) use `StatsVector: VectorArithmetic` to animate between point counts. The polyline morphs rather than swapping, using `withAnimation(.spring)`. The number of intermediate states is always `max(old, new)` points, with the shorter series padded to zero before the animation starts.

### Color semantics (universal on stats tab)

| Color | Token | Meaning |
|---|---|---|
| Blue (`ST.down`) | `statsDown` | Screen time went DOWN vs comparison period |
| Amber (`ST.up`) | `statsUp` | Screen time went UP |
| Cream (`ST.flat`) | `statsFlat` | Flat / unknown / insufficient data |

These apply to: chart line + band + dots + Ø pill, sparkline rows, header verdict, flow tile arrows. No red or green anywhere on the stats tab.

---

## Onboarding (11 steps)

```
Step 1:  Splash ("Hey. I'm Screeny." — tap to begin)
Step 2:  Name ask (screenyUserName, cannot tap-skip)
Step 3:  Hook (ghost talks, sets up the premise)
Step 4:  Screen Time permission (Opal-style popup + gradient ring, loading/deny-retry)
Step 5:  Pick apps (FamilyActivityPicker embedded inline, faded edges)
Step 6:  Daily limit (BigNumberPicker)
Step 7:  Schedule (time range picker)
Step 8:  Key (scan explanation — one scan locks, next unlocks)
Step 9:  Notifications permission (popup replica + benefit rows)
Step 10: Done (personalized, with the user's name)
Step 11: Hold-to-commit ceremony (starts the daily streak)
```

All onboarding screens are dark regardless of the system theme. `screenyApp` forces `.colorScheme(.dark)` while `!hasOnboarded`.

`OnboardingFlowView` is parameterized with `initialStep: Int` for simulator testing without the full flow. In production, `initialStep` is always 0.

---

## Settings sheet

```
SettingsSheetView
├── Setup card (name, default limit, language, theme)
├── Defaults card (default limit, schedule)
├── Personalized breaks (CoachEditor)
│   ├── Mode tiles (Off / Gentle / Balanced / Strict)
│   └── App exclusion strip (horizontal scroll)
├── Locking card (hold duration, immediate unlock toggle)
├── Notifications (NotificationsEditor — warn80, weekly push, daily push)
└── About card (Privacy, Terms, Contact, version)
```

`SettingsSheetView` accepts a `settingsTarget: SettingsTarget?` parameter. When non-nil, the sheet scrolls to and highlights the target section on appear. `SettingsTarget` values: `.coach`, `.limit`, `.schedule`, `.notifications`. The scroll happens synchronously in `onAppear` — a dispatched flip never re-renders a fresh sheet correctly.

---

## App picker

`AppLibraryPickerView` wraps `FamilyActivityPicker` with two important layers:

1. **Category stripping:** `stripUnsupportedPicks(pickedCategory:notice:)` removes any `ActivityCategoryToken` from the selection immediately. Categories are broad and inconsistent (Apple's "Social" includes random apps). When a category is stripped, `LockedNoticeCenter` shows a HUD: "Categories aren't supported — add individual apps instead."

2. **Mode switching:** The picker can be opened in `.block` or `.allowOnly` mode. The mode switcher is a "Separate apps / One folder" grouping control at the bottom.

---

## Design system

### Fonts
- Primary: `Hanken Grotesk` (variable, loaded via `@Font.custom`)
- Editorial: `Newsreader` (variable, stats tab headline and flow detail)
- **Critical:** Variable fonts must use `Font.custom("Name-Regular").weight(.bold)` — never the CoreText matrix path. The matrix path produces incorrect weight rendering on variable fonts.

### Colors (ScreenyTheme)
Screeny uses a Furniture-dark palette: dark backgrounds with cream text, amber accents, and contextual blue (allow-only mode chrome).

| Token | Usage |
|---|---|
| `FC.background` | Base page background |
| `FC.surface` | Card surface |
| `FC.text` | Primary text |
| `FC.text2` | Secondary text |
| `FC.text3` | Tertiary / hint text |
| `FC.amber` | Accent, lock state, warning |
| `FC.blue` | Allow-only mode chrome |
| `FC.cream` | Neutral surface, unselected state |
| `ST.down` | Stats: reduction (blue) |
| `ST.up` | Stats: increase (amber) |
| `ST.flat` | Stats: flat/unknown |

### ScreenyBackground
`ScreenyBackground` provides a two-tone aurora effect (subtle radial gradients from the bottom corners) that is shared across every page including folder detail. The aurora color varies by page context (amber warmth on locked pages, neutral on the home screen).

### Notices
`LockedNoticeCenter.shared.show(_:)` is a global HUD capsule that appears at the bottom of the screen. It is used for picker rejections, scan feedback, and error messages. It auto-dismisses after 3 seconds. It does not block interaction.

### Coach spotlight (FirstUseCoach)
`FirstUseCoach.swift` implements the first-use tutorial overlay. A blurred full-screen backdrop with a tight bordered frame that hugs the target element. `rectProvider` closures allow spotlighting arbitrary elements that don't have `anchorPreference` values.

**Known gotcha:** `@State` values set inside child `struct` bodies do not propagate to the parent's `overlayPreferenceValue`. Spotlight anchors must be set in the parent view's body. The nav-bar tour uses `navTourRect` to slice the whole-tab-bar anchor into thirds, rather than trying to spot per-segment anchors.
