# Chapter 9 — Alternatives Explored & Rejected

Every major design fork in Screeny's history, with the rationale for the path not taken.

---

## Alternative: DeviceActivityReport extension for the stats chart

**What was tried (builds 16-19):** The stats chart was drawn inside the `ScreenyActivityReport` extension. This would have given access to real Screen Time usage data from the OS — including pre-install history, other devices, exact minute counts.

**Why it was rejected:**
1. **No touch events.** The extension is rendered in a remote sandbox. `onTapGesture`, `DragGesture`, and any gesture recognizers inside the extension view receive nothing. Interactive charts were physically impossible.
2. **No App Group writes (device).** The extension *can* be coded to write to the App Group, and it works in the simulator. On a physical device, the sandbox denies the write silently. This was discovered on TestFlight build 3 when all extension-written numbers were null on device. There is no entitlement that grants this permission.
3. **Cold-start delay on every reopen.** The extension process can be killed between tab visits. Every cold-start added 2-5 seconds of blank screen.
4. **No persistent cache.** The app-side hosting cache (`StatsReportHostCache`) partially solved the reopen problem but the underlying issue remained.

**Verdict:** Irreversibly rejected. The tick-ladder approach (current) gives worse number accuracy but full interactivity and instant render.

---

## Alternative: NFCNDEFReaderSession instead of NFCTagReaderSession

**What was tried:** Initial NFC implementation used `NFCNDEFReaderSession`, which reads NDEF-formatted tags and returns structured records.

**Why it was rejected:**
App Store validation rejected the build with "NDEF is disallowed." The profile granted TAG+PACE formats but not NDEF as a standalone session type. The NDEF entitlement key (`com.apple.developer.nfc.readersession.formats`) cannot list NDEF with TAG on the same entitlement in the distribution profile.

**Current approach:** `NFCTagReaderSession` (TAG format) with `mifareTag.readNDEF()` — reads NDEF content via the TAG session. The app gets identical data; the entitlement difference is only in the session type declaration.

---

## Alternative: App Store category browsing in the picker

**What was tried:** `AppLibraryPickerView` originally showed a "Your categories" section, letting users pick whole Apple Screen Time categories (Social, Entertainment, etc.) to block.

**Why it was rejected:**
Apple's categories are broad and inconsistent. "Social" includes apps users don't want blocked. "Entertainment" has games and streaming apps mixed. When Screeny blocked "Entertainment," users were surprised and frustrated that unrelated apps were shielded.

More fundamentally, Screeny is built around per-app rules with per-app stats. Category blocks are incompatible with "how much time did I spend in Instagram specifically."

**Current approach:** Categories are stripped from every picker return via `stripUnsupportedPicks`. If a user tries to select a category, a HUD notice appears: "Categories aren't supported — add individual apps instead."

---

## Alternative: ScreenyShieldAction extension (shield Close button)

**What was tried:** A `ScreenyShieldAction` extension was implemented and added to the project. It answered `.close` from the shield, making the "Close" button work as a "close the shield and go back to what I was doing" action.

**Why it was rejected:**
App Store validation rejected the extension with the message that `com.apple.ManagedSettingsUI.shield-action-service` is not a valid standalone extension point. The built binary was byte-for-byte correct but the extension type was unacceptable.

**Current approach:** The button works via iOS default shield behavior. Without a shield-action extension, iOS automatically wires the primary button to dismiss the shield and return to the Home screen. Users cannot open Screeny from the shield (iOS doesn't allow that from within a shield extension), but they can close the shield and navigate there manually.

---

## Alternative: Multiple separate ScreenyShieldAction + ShieldConfig targets

**What was tried:** The original project had 5 extension targets including both a `ScreenyShieldConfig` and `ScreenyShieldAction`.

**Why consolidated:**
App Store validation failure on `ScreenyShieldAction` (see above). The action target was removed entirely from `project.pbxproj`. The project now has 4 targets.

---

## Alternative: User-facing dummy mode in Settings

**What was tried:** A "Dummy mode" row in the Settings sheet let users toggle the `screenyDummyMode` flag from the UI, enabling sample data without simulator tools.

**Why it was rejected:**
This was explicitly requested to be removed. Exposing internal development tooling to end users creates confusion and support burden. The flag remains as a developer tool (set via `UserDefaults.standard.set(true, forKey: "screenyDummyMode")` in Xcode), but is never accessible through the shipped UI.

---

## Alternative: DEBUG screenshot harness

**What was tried:** `ContentView.swift` had a `#if DEBUG` gated screenshot harness — `ScreenyDebugRoute`, `ScreenyDebugStore`, `ScreenyDebugHost` — that could render any screen in isolation for screenshots and UI testing.

**Why it was rejected:**
Explicitly requested to be removed before first public release. It was never shipped (guarded by `#if DEBUG`) but added complexity and dead code. Removed in build 14.

---

## Alternative: Spanish localization

**What was tried:** The original `ScreenyL10n.swift` had a Spanish (`es`) language option with a partial translation set.

**Why it was rejected:**
Spanish strings were incomplete and the author didn't have a Spanish speaker to verify. Shipping a partial translation is worse than shipping none. The old ES strings are preserved in git history. A full Spanish translation would require a native speaker to review.

**Current state:** English and German only. Language picker shows English / Deutsch.

---

## Alternative: Supabase analytics layer

**What was tried:** A branch (`analytics`, unpushed) added Supabase analytics — onboarding funnel events, feature usage counts, RLS-secured with a `submit_onboarding` RPC.

**Why not merged yet:**
RLS configuration had a `deny-all SELECT` rule that broke the `upsert`/`PATCH` path. The analytics layer was working but the RLS policy needed adjustment. It wasn't merged because the focus was on device-testing the blocking features first.

**Status:** On the `analytics` branch, not on `main`. Unblocked whenever there's capacity.

---

## Alternative: Auto-assigning the onboarding key to all flows

**What was tried:** After onboarding created a default NFC key, `assignOnboardingKeyToFlows()` automatically set that key's token on all new flows.

**Why it was rejected:**
Keys are personal objects — the user may have multiple tags on their desk, one per flow. Auto-assignment created unexpected behavior: scanning one tag would trigger all flows. Keys are now always assigned manually from the flow's Key tile.

---

## Alternative: `NFC NDEF` entitlement (original NFC approach)

**What was tried:** The original entitlement listed `NDEF` in `com.apple.developer.nfc.readersession.formats`.

**Why it was rejected:**
App Store validation failure: "NDEF is disallowed." The scanner had already been rewritten to use `NFCTagReaderSession` internally (which can read NDEF content), but the entitlement declaration was still listing the `NFCNDEFReaderSession` format. Only `TAG` and `PACE` remain in the entitlement.

---

## Alternative: Single-store ManagedSettings (one store for all blocking)

**What was tried (conceptually):** Using a single `ManagedSettingsStore` for all blocking (both manual and schedule-based).

**Why rejected before implementation:**
The monitor extension and main app write blocking state at different times, triggered by different events. If they share a store, each write completely replaces the other's state. A schedule block at 9pm would wipe the manual lock set 5 minutes ago. Two separate stores compose correctly — each process owns its own store, and iOS takes the union for enforcement.

---

## Alternative: Token-to-bundle-ID mapping

**What was tried:** Various approaches to extract the bundle ID from an `ApplicationToken`:
1. Reflection into private fields
2. `Application(token:).localizedDisplayName` (returns nil under individual auth)
3. Cross-referencing the token with the installed app list

**Why abandoned:**
Token opacity is an intentional privacy design. Apple specifically designed tokens to be unlinkable to bundle IDs without the user's consent. Any private API approach would be App Store-rejected. The correct approach is the shield-harvest workaround already in place.

**Documentation confirming this:** https://developer.apple.com/forums/thread/681493 — Apple engineer confirms `Application(token:).localizedDisplayName` is only available under parental/supervised authorization.

---

## Alternative: Real-time usage polling

**What was tried (conceptually):** Polling the Screen Time API periodically for current usage to drive live stats.

**Why impossible:**
There is no Screen Time API that can be called on a timer to return "current usage." `DeviceActivityReport` only works inside the extension's sandboxed view. The only notification mechanism is `DeviceActivityEvent` threshold callbacks, which are what the tick ladder uses.
