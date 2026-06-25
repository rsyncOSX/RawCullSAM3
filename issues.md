# Bursts Group and AI Verification Report

Date: 2026-06-25

## Scope and verification performed

Reviewed the burst grouping, ranking, review queue, cache, CLIP similarity, SAM3 deep-review, catalog lifecycle, comparison/grid integration, and relevant `RawCullCore` 1.1.0 dependency code.

Verification completed:

- Debug app build: **passed**
- Targeted test suites (`SimilarityEmbeddingBackendTests`, `CullingModelTests`, `CullingGridCoordinatorTests`, `SharpnessScoringTests`): **passed**
- Project concurrency settings verified: Swift 6, MainActor default isolation, Approachable Concurrency enabled

The clean build and current tests do not cover the behavioral failures below.

## Findings

### 1. [P1] The stored burst-analysis task is not the task that performs the analysis

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:127-182`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:940-951`

`analyzeBursts()` cancels `burstAnalysisTask`, then stores an empty `Task {}`. The actual analysis continues inside the caller's task. Consequently, `clearLoadedBurstAnalysisForReindex()` cancels only the empty placeholder, not sharpness scoring, similarity indexing, grouping, ranking, cache saving, or later state writes from the old analysis.

Impact:

- Reanalyzing while an old run exists can allow both runs to mutate the same models.
- Clearing/reindexing can be followed by stale results from the prior run.
- Catalog changes can receive late state writes or cache writes from a previous catalog.
- Cancellation guards check the caller task, which is unrelated to the stored placeholder.
- Early cancellation exits can leave `burstAnalysisProgress` stuck on a running step.

Recommendation: make one owned task execute the complete pipeline, add a generation/catalog identity check before every state commit, and clear progress/task state in a cancellation-safe `defer`.

### 2. [P1] Catalog switching does not reset or cancel burst and deep-AI state

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+Catalog.swift:9-78`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel.swift:80-87`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:232-382`

`cancelCatalogLoad()` resets sharpness, similarity, and mask inventory, but it does not cancel/reset:

- `burstAnalysisTask`
- `burstAnalysisProgress`
- `burstAnalysisResults`
- `burstReviewStates`
- `activeBurstComparisonGroupID`
- `lastBurstUndoEntry`
- `deepAIReviewModel.results`, presentation, or running state

Deep review also has no stored task that catalog switching can cancel.

Impact:

- Review counts and statistics can temporarily describe the previous catalog.
- A running old analysis or deep review can publish results after another catalog is selected.
- Deep results are keyed by small integer group IDs, so old results can appear on a new catalog's group with the same ID.

Recommendation: add one catalog-scoped reset/cancellation method and require the selected catalog identity to match before every async result is applied.

### 3. [P1] The burst cache ignores the embedding backend and burst sensitivity

Locations:

- `RawCullSAM3/Actors/BurstAnalysisCache.swift:4-18`
- `RawCullSAM3/Actors/BurstAnalysisCache.swift:168-190`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:137-146`
- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:474-490`

The cache snapshot and validity check include file metadata, grouping algorithm version, thumbnail size, and sharpness settings, but not:

- selected embedding backend (`CLIP` versus Vision)
- CLIP model/version
- embedding envelope/version
- burst sensitivity (`visualDistanceThreshold`)
- other grouping configuration values

`analyzeBursts()` returns immediately on a valid cache hit before checking the currently selected embedding backend.

Impact:

- Enabling or disabling CLIP can continue using cached embeddings/groups from the previous backend.
- Changing burst sensitivity can be undone on the next load or Analyze Bursts action by the old cache.
- Model upgrades can silently reuse results from an older AI model.

Recommendation: persist and validate a complete similarity/grouping signature. Increment the cache schema when adding it.

### 4. [P1] Per-image CLIP fallback creates mixed embeddings that force false burst boundaries

Locations:

- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:251-375`
- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:559-596`
- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:599-623`
- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:666-678`
- `RawCullCore/BurstGroupingEngine.swift:40-48` (resolved package 1.1.0)

When CLIP fails for one image, only that image falls back to a Vision feature print. CLIP and Vision embeddings cannot be compared, so `distance(from:to:)` returns `nil`. The grouping engine treats missing distance as a mandatory new group.

Impact:

- A transient CLIP failure on one frame splits an otherwise valid burst before and/or after that frame.
- A mixed catalog repeatedly retries Vision-fallback files because `hasCurrentEmbeddings` requires the preferred backend for every file.
- The UI reports a mixed backend, but the grouping result is structurally degraded rather than merely lower confidence.

Recommendation: keep one comparable backend for the whole grouping pass. If any CLIP embedding fails, either retry, compute Vision embeddings for all files used by that pass, or exclude the failed frame with an explicit degraded-analysis state.

### 5. [P1] Review states are reassigned to different bursts after regrouping

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:202-211`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:614-626`
- `RawCullCore/BurstGroupingEngine.swift:85-93` (resolved package 1.1.0)

Group IDs are regenerated from array offsets whenever sensitivity changes. `reGroupBursts()` then ranks the new groups while passing the old `burstReviewStates` dictionary keyed by those offsets.

Impact:

- A state such as Reviewed, Deferred, Needs Review, Decision Applied, or Manual Winner can be attached to a different membership after regrouping.
- The cache-loading path correctly has signature-based restoration, but the live regroup path bypasses that protection.

Recommendation: snapshot review states by `BurstGroupSignature` before regrouping and restore them by membership signature afterward. Never treat the integer offset as persistent identity.

### 6. [P2] Singleton groups pollute review queues but have no group review UI

Locations:

- `RawCullCore/BurstGroupingEngine.swift:23-24,85-93` (resolved package 1.1.0)
- `RawCullCore/BurstRankingEngine.swift:13-23,74-105` (resolved package 1.1.0)
- `RawCullSAM3/Model/ViewModels/BurstReviewQueueModels.swift:21-79`
- `RawCullSAM3/Views/CullingGrid/CullingGridView.swift:467-489`

The grouping engine emits every isolated image as a one-file `BurstGroup`. The ranking engine creates a result for every group, and the review policy counts non-high-confidence results as Needs Review. However, the grid hides the burst header and all review actions when a group has only one visible file.

Impact:

- Needs Review can include ordinary singleton photos.
- Opening the queue shows items that cannot be reviewed, deferred, or marked reviewed from the group header.
- Counts can significantly overstate actual bursts in sparse catalogs.

Recommendation: exclude groups with fewer than two members from burst ranking/review queues, or provide explicit singleton handling and actions.

### 7. [P2] Deep-AI results use unstable group IDs despite already carrying a membership signature

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:58-75`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:228-256`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:819-854`
- `RawCullSAM3/Views/CullingGrid/CullingGridView.swift:691-713`

`DeepAIReviewResult` contains `groupSignature`, but results are stored and retrieved only by `groupID`. No code validates that the signature still matches the current group after regrouping, reanalysis, filtering, or catalog changes.

The sheet close path automatically marks the current result's recommendation as a manual winner.

Impact:

- Stale deep-review evidence can be displayed for changed membership.
- Closing the sheet can apply a stale recommendation to a regrouped burst when the recommended file is still a member.

Recommendation: key or validate deep results by catalog plus `BurstGroupSignature`; invalidate mismatches before display and before winner persistence.

### 8. [P2] “Eye Detail” is functionally identical to “Head / Face”

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:644-719`
- `RawCullSAM3/Model/ViewModels/FocusandSharpness/FocusMaskEngine+Scoring.swift:458-669`

Both presets use the same prompt routing, the same accepted prompt set, and the same deep sharpness computation. There is no eye prompt, eye-region localization, or eye-specific scoring window.

Impact:

- The UI promises a distinct eye-detail analysis that is not implemented.
- Users can make culling decisions believing the score is eye-specific when it is only head/face-mask detail.

Recommendation: either implement eye localization/scoring or remove/rename the preset until it has distinct behavior.

### 9. [P2] Similarity cancellation does not cancel the detached per-file workers

Locations:

- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:284-370`
- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:559-596`

The indexing task group calls `computeEmbedding`, which immediately creates an unstructured `Task.detached`. Cancellation of the group child does not propagate into that detached task.

Impact:

- The Cancel button can clear UI state while RAW decoding, Vision work, or CLIP inference continues.
- Starting another index can overlap expensive work with the cancelled pass.
- The shared CLIP provider can remain occupied by requests whose results will be discarded.

Recommendation: remove the nested detached task and execute cancellable work directly in the structured child task, with cancellation checks around decode and inference.

### 10. [P2] Grid cache invalidation can leave stale group membership and “best” labels

Locations:

- `RawCullSAM3/Views/CullingGrid/CullingGridRenderCache.swift:9-53`
- `RawCullSAM3/Views/CullingGrid/CullingGridRenderCache.swift:61-103`
- `RawCullSAM3/Views/CullingGrid/CullingGridView.swift:663-685`

The cache key hashes only:

- each group ID and member count, not member IDs
- file count plus first/last ID, not the complete visible file set
- sharpness score count, not score values or `maxScore`

Impact:

- Regrouping can change members without changing group counts/member counts, leaving old visible sections.
- Filtering can replace middle files while retaining count/first/last, leaving old visible files.
- Recalculation with the same number of scores can leave stale best-frame names and percentages.

Recommendation: use deterministic signatures of group member IDs, visible file IDs, relevant score values/version, and `maxScore`.

### 11. [P2] Saving review state can overwrite the cache with a different analysis scope

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:578-590`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:916-921`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:954-977`

Review-state persistence rebuilds the snapshot using the *current* `burstAnalysisTargetFiles`. That target changes with thumbnail selection and star filters, while groups/results/embeddings may still represent the scope used by the prior analysis.

Impact:

- Marking a group after changing selection/filter can replace a valid full-catalog cache with a one-file or filtered file manifest while retaining full-scope groups/results.
- The next load generally rejects the cache due to file-count mismatch and unnecessarily recomputes the whole analysis.
- If the same filtered scope is later used, the accepted snapshot can contain groups whose members are absent from its file manifest.

Recommendation: store the immutable file scope/signature of the completed analysis and use that scope for all later review-state saves.

### 12. [P3] Large burst-cache JSON encoding and decoding is forced onto MainActor

Locations:

- `RawCullSAM3/Actors/BurstAnalysisCache.swift:118-152`

The cache actor reads/writes files itself, but moves JSON decoding and encoding to `MainActor`. Snapshots include all embedding blobs, scores, saliency data, groups, and results.

Impact:

- Large catalogs can visibly block the UI while loading or saving the cache.
- Frequent review-state saves repeat full-snapshot encoding on the UI actor.

Recommendation: make cache DTOs safely nonisolated/Sendable and perform serialization inside the cache actor or a cancellable background task.

## Missing regression coverage

Add tests for:

- cancelling an active analysis and proving no later state/cache mutation occurs
- switching catalogs during burst analysis and deep review
- cache invalidation after CLIP/Vision setting, model version, or sensitivity changes
- mixed CLIP/Vision fallback behavior at adjacent frames
- review-state restoration after live regrouping by membership signature
- singleton exclusion from review counts
- deep-result signature mismatch after regrouping/catalog change
- complete render-cache invalidation when middle members or score values change
- persistence after changing selection/rating filter following analysis
