# RawCullSAM3 — SAM3 & Zoom View Findings

This document records findings from a read-only review of the SAM3 integration and
its use in `ZoomOverlayView`. No code was changed.

---

## 1. `ExternalSAM3Provider` is referenced in documentation but does not exist

`sam3.md` states:

> `ExternalSAM3Provider` remains in the project for explicit debug/test injection,
> but `SubjectSegmentationActor()` defaults to the local Core AI SAM3 provider.

A full search of the Swift source tree finds no file or type named `ExternalSAM3Provider`.
The documentation is out of sync with the codebase — either the type was removed and the
note not updated, or it was never added.

**Affected file:** `sam3.md` (documentation claim)  
**Impact:** Misleading. Developers looking for a test-injection provider will not find it.

---

## 2. No automated tests for the entire SAM3 pipeline

The subject segmentation pipeline has **zero unit tests** in `RawCullSAM3Tests/`:

| Type | File | Tests |
|---|---|---|
| `SubjectSegmentationActor` | `SubjectSegmentationActor.swift` | None |
| `CoreAISAM3Provider` | `CoreAISAM3Provider.swift` | None |
| `SubjectMaskCache` | `SubjectMaskCache.swift` | None |
| `SubjectSegmentationTypes` | `SubjectSegmentationTypes.swift` | None |

`SubjectSegmentationActor` already has a dependency-injection constructor:

```swift
init(
    provider: any SubjectSegmentationProvider,
    cache: SubjectMaskCache,
    maxSide: Int = 4320,
)
```

This is exactly the right shape for unit testing with a stub provider, but nothing
in the test target currently uses it.

`ZoomOverlayView` also exercises several distinct SAM3 state transitions
(toggle on/off, prompt change, navigation cancel, source-switch cancel), none of which
are covered by the existing `ZoomOverlayKeyActionTests.swift`.

`TEST_ARCHITECTURE.md` lists "zoom overlay" as a current focus area but does not
mention subject segmentation.

**Impact:** Regressions in the SAM3 path — caching, stale-response handling,
cancellation, prompt changes — will not be caught by CI.

---

## 3. `SubjectSegmentationControlsView.iconName` has a dead / duplicate branch

In `SubjectSegmentationControlsView` (`FocusPeek/SubjectSegmentationControlsView.swift`,
lines 106–113), the `iconName` property returns the same symbol for both the
"mask shown" and "mask hidden" states:

```swift
private var iconName: String {
    if state.isLoading {
        "sparkle.magnifyingglass"
    } else if showSubjectMask {
        "sparkles.square.filled.on.square"   // active
    } else {
        "sparkles.square.filled.on.square"   // ← same as active; no visual change
    }
}
```

The sibling `SubjectMaskToggleButton` (same file, lines 205–210) correctly
distinguishes three states:

```swift
private var iconName: String {
    if showSubjectMask {
        return "sparkles.square.filled.on.square"
    }
    return maskAvailable ? "sparkles.square.on.square" : "sparkle.magnifyingglass"
}
```

The `SubjectSegmentationControlsView` button is the one rendered in `ZoomOverlayView`
(via `ImageOverlayControlsView`). Users see the same icon whether the mask is on or
off, providing no visual feedback about the toggle state.

**Affected file:** `Views/FocusPeek/SubjectSegmentationControlsView.swift`  
**Impact:** Usability — the button icon does not change when the subject mask is toggled.

---

## 4. `SubjectMaskCache` is unbounded (no eviction policy)

`SubjectMaskCache` is a plain dictionary with no size limit or eviction:

```swift
actor SubjectMaskCache {
    private var entries: [SubjectMaskCacheKey: SubjectMaskCacheEntry] = [:]
    // no removeAll() is ever called during a session
}
```

`removeAll()` exists but is never called from production code paths.
Each `SubjectMaskCacheEntry` holds a `SubjectSegmentationResult` that contains a
`CGImage` (the mask). In a long culling session with many images and several prompts
per image, mask images accumulate for the lifetime of the `ZoomOverlayView` state.

**Affected file:** `Model/SubjectSegmentation/SubjectMaskCache.swift`  
**Impact:** Memory growth in long photo sessions. No immediate crash risk, but may
degrade performance on systems with limited RAM.

---

## 5. `@unchecked Sendable` retroactive conformances on third-party types

`CoreAISAM3Provider.swift` adds:

```swift
extension ImageSegmenter: @retroactive @unchecked Sendable {}
extension CoreAISegmentationEngine: @retroactive @unchecked Sendable {}
```

These bypass Swift Concurrency's thread-safety guarantees for types owned by
the `CoreAIImageSegmenter` package. If either type mutates shared state internally
(e.g. caches, counters), there is no compiler protection. The comment in the file
acknowledges this ("does not currently declare Sendable") but the workaround silences
all future compiler warnings about these types.

**Affected file:** `Model/SubjectSegmentation/CoreAISAM3Provider.swift`  
**Impact:** Potential data race risk if the Apple package updates either type's
internal threading behaviour. Should be revisited when the package ships a proper
`Sendable` declaration.

---

## 6. Temporary shim directory uses a fixed path — potential collision with multiple instances

`CoreAISAM3Provider.resourcesURLForImageSegmenter` (flat-layout fallback) writes to a
fixed path:

```swift
let shimURL = fileManager.temporaryDirectory
    .appendingPathComponent("RawCullSAM3", isDirectory: true)
    .appendingPathComponent("CoreAISAM3Bundle", isDirectory: true)
```

The actor serialises its own calls, so a single provider instance is safe. However,
`ZoomOverlayView` creates its own `@State private var subjectSegmentationActor = SubjectSegmentationActor()`,
which in turn creates its own `CoreAISAM3Provider()`. If two `ZoomOverlayView` instances
are ever alive concurrently (e.g. comparison views), they would share the same shim path
and could race on the `removeItem` / `createDirectory` / `copyItem` sequence inside
`resourcesURLForImageSegmenter`.

**Affected file:** `Model/SubjectSegmentation/CoreAISAM3Provider.swift`  
**Impact:** Low risk today (one zoom overlay at a time), but fragile. A UUID suffix on
the shim path would eliminate the concern.

---

## 7. ZoomOverlayView: subject mask is restricted to `.embeddedJPG` — undocumented in UI

The subject mask toggle is disabled (greyed out) and shows "SAM mask requires JPG"
when the image source is not `.embeddedJPG`. This is handled correctly in the code
(`subjectMaskEnabled: sourceSelection.selected == .embeddedJPG`). However there is no
explanatory tooltip on the disabled state in `ZoomOverlayView`'s toolbar — the
`ImageOverlayControlsView` passes `subjectMaskEnabled` as a binding but the disabled
control does not communicate *why* it is disabled to the user at the toolbar level.

**Affected files:** `Views/ZoomViews/ZoomOverlayView.swift`,
`Views/ThumbnailComponents/ImageOverlayControlsView.swift`  
**Impact:** Minor UX — users switching to developed RAW may not understand why the
SAM button becomes unavailable.

---

## Summary

| # | Severity | Type | Description |
|---|---|---|---|
| 1 | Medium | Documentation | `ExternalSAM3Provider` referenced in `sam3.md` does not exist in code |
| 2 | High | Testing gap | Zero tests for SAM3 pipeline (`Actor`, `Provider`, `Cache`) |
| 3 | Low | Bug | `SubjectSegmentationControlsView.iconName` returns same icon for on/off states |
| 4 | Medium | Memory | `SubjectMaskCache` is unbounded — no eviction policy |
| 5 | Low | Concurrency | `@unchecked Sendable` on third-party types bypasses Swift Concurrency checks |
| 6 | Low | Concurrency | Shim temp directory uses fixed path — unsafe if two provider instances run concurrently |
| 7 | Low | UX | Disabled SAM button doesn't explain why it is unavailable when not in JPG mode |
