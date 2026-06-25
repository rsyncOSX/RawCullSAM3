# Bursts Group and AI Verification Report

Date: 2026-06-25
Status: **All findings closed**

## Scope and verification performed

Reviewed the burst grouping, ranking, review queue, cache, CLIP similarity, SAM3 deep-review, catalog lifecycle, comparison/grid integration, and relevant `RawCullCore` 1.1.0 dependency code.

Verification completed:

- Debug app build: **passed**
- Targeted test suites (`SimilarityEmbeddingBackendTests`, `CullingModelTests`, `CullingGridCoordinatorTests`, `SharpnessScoringTests`): **passed**
- Full `RawCull` test plan with Thread Sanitizer: **244 tests passed, 0 failed, 0 skipped**
- Project concurrency settings verified: Swift 6, MainActor default isolation, Approachable Concurrency enabled

The findings below document the original problems, their resolutions, and why
closing each one was important.

## Closure summary

| # | Status | Commit | Resolution | Why closing it was important |
|---|---|---|---|---|
| 1 | Closed | `ba72a5e` | The stored task now owns the complete burst-analysis pipeline, with generation and catalog checks around state commits. | Prevents cancelled or superseded analyses from publishing stale results, corrupting cache state, or leaving progress stuck. |
| 2 | Closed | `d4c772c` | Catalog changes now cancel and clear burst analysis and deep-review state, including their owned tasks. | Prevents one catalog’s rankings, review counts, or AI recommendations from appearing in another catalog. |
| 3 | Closed | `e5da1e3` | Cache schema 4 validates the embedding backend, CLIP model identity, envelope version, and complete grouping configuration. | Ensures changed AI models, backends, or sensitivity settings actually produce fresh and trustworthy groups. |
| 4 | Closed | `c505cc7` | A failed or incomplete CLIP pass now recomputes the full scope with Vision instead of mixing embedding types. | Keeps all distances comparable so a transient failure cannot create false burst boundaries. |
| 5 | Closed | `83645a0` | Review states are restored by `BurstGroupSignature` membership rather than regenerated integer IDs. | Stops Reviewed, Deferred, or Manual Winner decisions from moving to unrelated bursts after regrouping. |
| 6 | Closed | `7cf4577` | Singleton groups are excluded from burst ranking and review results. | Makes review counts actionable and prevents ordinary single photos from appearing as unreviewable bursts. |
| 7 | Closed | `a221059` | Deep-review results and winner application now validate the current burst membership signature. | Prevents stale AI evidence or recommendations from being applied after regrouping or catalog changes. |
| 8 | Closed | `1ec7d09` | The duplicate “Eye Detail” preset was removed. | Avoids presenting head/face scoring as eye-specific analysis and misleading users during culling decisions. |
| 9 | Closed | `d008f0f` | Similarity embedding work now remains in structured tasks with cancellation checks around decode and inference. | Makes Cancel genuinely stop expensive work and prevents cancelled indexing from overlapping a new pass. |
| 10 | Closed | `0e2b7cb` | Grid cache identity now includes complete group membership, visible file IDs, score values, and `maxScore`. | Prevents stale sections, best-frame labels, and percentages after regrouping, filtering, or rescoring. |
| 11 | Closed | `c649814` | Review-state persistence now uses the immutable completed-analysis scope. | Prevents UI filters or selections from overwriting a valid full-scope cache with an inconsistent manifest. |
| 12 | Closed | `d79d6b9` | Cache DTO conformances are explicitly nonisolated and JSON encoding/decoding runs inside the cache actor instead of `MainActor`. | Prevents large cache payloads from blocking UI interaction while preserving Swift 6 isolation safety. |

## Findings

### 1. [P1] [Closed] The stored burst-analysis task is not the task that performs the analysis

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

### 2. [P1] [Closed] Catalog switching does not reset or cancel burst and deep-AI state

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

### 3. [P1] [Closed] The burst cache ignores the embedding backend and burst sensitivity

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

### 4. [P1] [Closed] Per-image CLIP fallback creates mixed embeddings that force false burst boundaries

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

### 5. [P1] [Closed] Review states are reassigned to different bursts after regrouping

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:202-211`
- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:614-626`
- `RawCullCore/BurstGroupingEngine.swift:85-93` (resolved package 1.1.0)

Group IDs are regenerated from array offsets whenever sensitivity changes. `reGroupBursts()` then ranks the new groups while passing the old `burstReviewStates` dictionary keyed by those offsets.

Impact:

- A state such as Reviewed, Deferred, Needs Review, Decision Applied, or Manual Winner can be attached to a different membership after regrouping.
- The cache-loading path correctly has signature-based restoration, but the live regroup path bypasses that protection.

Recommendation: snapshot review states by `BurstGroupSignature` before regrouping and restore them by membership signature afterward. Never treat the integer offset as persistent identity.

### 6. [P2] [Closed] Singleton groups pollute review queues but have no group review UI

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

### 7. [P2] [Closed] Deep-AI results use unstable group IDs despite already carrying a membership signature

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

### 8. [P2] [Closed] “Eye Detail” is functionally identical to “Head / Face”

Locations:

- `RawCullSAM3/Model/ViewModels/RawCullViewModel+BurstGrouping.swift:644-719`
- `RawCullSAM3/Model/ViewModels/FocusandSharpness/FocusMaskEngine+Scoring.swift:458-669`

Both presets use the same prompt routing, the same accepted prompt set, and the same deep sharpness computation. There is no eye prompt, eye-region localization, or eye-specific scoring window.

Impact:

- The UI promises a distinct eye-detail analysis that is not implemented.
- Users can make culling decisions believing the score is eye-specific when it is only head/face-mask detail.

Recommendation: either implement eye localization/scoring or remove/rename the preset until it has distinct behavior.

### 9. [P2] [Closed] Similarity cancellation does not cancel the detached per-file workers

Locations:

- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:284-370`
- `RawCullSAM3/Model/ViewModels/SimilarityScoringModel.swift:559-596`

The indexing task group calls `computeEmbedding`, which immediately creates an unstructured `Task.detached`. Cancellation of the group child does not propagate into that detached task.

Impact:

- The Cancel button can clear UI state while RAW decoding, Vision work, or CLIP inference continues.
- Starting another index can overlap expensive work with the cancelled pass.
- The shared CLIP provider can remain occupied by requests whose results will be discarded.

Recommendation: remove the nested detached task and execute cancellable work directly in the structured child task, with cancellation checks around decode and inference.

### 10. [P2] [Closed] Grid cache invalidation can leave stale group membership and “best” labels

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

### 11. [P2] [Closed] Saving review state can overwrite the cache with a different analysis scope

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

### 12. [P3] [Closed] Large burst-cache JSON encoding and decoding is forced onto MainActor

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

## Implementation plan

### Guiding design

Introduce a catalog-scoped analysis context and make it the authority for every
burst-analysis and deep-review state write:

- `catalogURL`: standardized URL for the catalog that started the work
- `generation`: a new token for each analysis/reset
- `files`: the immutable file scope used by the completed analysis
- `fileSignature`: deterministic identity for that scope

An async operation may commit results only when both its catalog URL and
generation still match the active context. Integer burst group IDs remain
presentation-local identifiers; persisted review and deep-review identity must
use `BurstGroupSignature`.

Implement the work in the phases below. Each phase should land with its tests
passing before starting the next phase.

### Phase 1 — Own and cancel catalog-scoped work (findings 1, 2, and 9)

1. Add ignored task handles and a generation token to `RawCullViewModel`:
   `burstAnalysisTask`, `deepAIReviewTask`, and `burstAnalysisGeneration`.
   Keep the immutable completed-analysis context alongside them.
2. Split `analyzeBursts()` into:
   - a public method that cancels the previous task, advances the generation,
     creates and stores the one task that owns the complete pipeline, and awaits
     that task;
   - a private pipeline method that receives the captured catalog, generation,
     and file scope.
3. Add a single `isCurrentBurstAnalysis(catalog:generation:)` guard and call it
   after every suspension point and immediately before applying cache data,
   rankings, progress, or cache writes.
4. Use cancellation-safe cleanup so only the current generation can clear
   `burstAnalysisTask` and return `burstAnalysisProgress` to idle.
5. Add `resetCatalogScopedAnalysis()` and call it at the beginning of catalog
   cancellation/switching. It must cancel both owned tasks and clear burst
   progress/results/review state, comparison state, undo state, completed scope,
   and all deep-review result/presentation/running state.
6. Give deep review the same catalog/generation ownership model. Check the
   captured context before each partial-result publication and final result.
7. Remove the nested `Task.detached` from
   `SimilarityScoringModel.computeEmbedding`. Run decode/inference directly in
   the structured task-group child and add cancellation checks before decode,
   before inference, and before returning a result.
8. Ensure cancellation discards temporary indexing results rather than merging
   a partially cancelled pass into `embeddings`.

Acceptance criteria:

- Reanalysis leaves at most one pipeline capable of writing state or cache.
- Cancel/reindex and catalog switching always return progress to idle.
- An old catalog cannot publish burst or deep-review state into a new catalog.
- Cancelling similarity indexing stops child workers and does not merge late
  embeddings.

Tests:

- Add controllable test hooks/fakes that suspend sharpness, embedding, deep
  review, and cache save stages.
- Cancel or switch catalogs while suspended, resume the old work, and assert no
  progress, results, deep results, embeddings, or cache writes are published.
- Start two analyses and assert only the newest generation commits.

### Phase 2 — Define complete analysis and cache identity (findings 3, 11, and 12)

1. Add a codable, equatable, sendable `BurstSimilarityGroupingSignature`
   containing:
   - selected embedding backend;
   - CLIP model identifier/version when CLIP is selected;
   - embedding envelope format version;
   - grouping algorithm version;
   - `visualDistanceThreshold`;
   - every other grouping configuration value that can change boundaries.
2. Store this signature in `BurstAnalysisCacheSnapshot`, require it in
   `BurstAnalysisCache.load`, and increment `BurstAnalysisCache.schemaVersion`.
   Compute the preferred backend and signature before attempting a cache load.
3. On successful analysis or cache load, store a
   `CompletedBurstAnalysisContext` containing the immutable catalog URL, files,
   file signature, and analysis signature.
4. Change review-state persistence to use the completed context instead of
   `burstAnalysisTargetFiles`. Refuse to save if current groups/results do not
   match that context.
5. Move JSON encode/decode off `MainActor`. Mark cache DTOs `Sendable` where
   valid and perform serialization in the cache actor or a cancellable
   background worker.
6. Avoid rebuilding a snapshot from mutable UI filters for review-only changes.
   Add a cache-actor operation that updates review snapshots on the stored
   completed snapshot, then atomically rewrites it.
7. Coalesce rapid review-state saves so repeated clicks do not serialize the
   full embedding payload for every intermediate state.

Acceptance criteria:

- Backend, CLIP model/envelope version, sensitivity, or grouping-config changes
  invalidate the cache.
- Selection, search, and rating-filter changes after analysis do not alter the
  cache file manifest.
- Cache serialization does not execute on the main actor.
- Review updates preserve the original completed analysis scope.

Tests:

- Add cache round-trip and invalidation tests for each signature component.
- Analyze a full scope, change selection/filter, persist review state, reload,
  and assert the original manifest, groups, and restored review state remain
  valid.
- Add an executor/isolation assertion around cache encoding and decoding.

### Phase 3 — Guarantee one comparable embedding backend per pass (finding 4)

1. Make indexing transactional: compute results into a temporary pass result
   and publish them only after the backend decision is final.
2. For a CLIP pass, retry failed CLIP items according to a small bounded policy.
   If any required item still fails, discard temporary CLIP results and compute
   Vision embeddings for the entire requested analysis scope.
3. Record the effective backend and degraded/fallback reason in the completed
   analysis context and cache signature. Do not permit mixed-backend embeddings
   in a grouping pass.
4. Update UI status/logging to say that the pass fell back to Vision, rather
   than reporting a structurally mixed index.
5. Add an invariant check before grouping that all required files have
   embeddings from one backend. If not, fail the pass visibly instead of
   creating false boundaries.

Acceptance criteria:

- A single CLIP failure cannot split a burst because of incomparable adjacent
  embeddings.
- Completed grouping scopes contain only CLIP or only Vision embeddings.
- A fallback pass is reusable and does not retry CLIP for individual files on
  every analysis.

Tests:

- Inject a CLIP failure for the middle frame of a burst and assert the whole
  scope falls back to Vision and remains one group.
- Cover retry success, full fallback, cancellation during fallback, and failure
  to produce a complete fallback index.

### Phase 4 — Preserve stable burst and deep-review identity (findings 5 and 7)

1. Before `reGroupBursts()`, snapshot all non-empty review states by
   `BurstGroupSignature` using the completed analysis file lookup and catalog.
2. After regrouping/reranking, rebuild `burstReviewStates` by matching the new
   group signatures. Do not pass the old integer-keyed dictionary into ranking.
3. Replace `DeepAIReviewModel.results: [Int: DeepAIReviewResult]` with storage
   keyed by a catalog-aware `BurstGroupSignature` (or a key containing catalog
   identity plus the signature). Keep group ID only as display metadata.
4. Resolve a deep result for display by computing the current group's signature.
   Remove or ignore results whose signature no longer matches.
5. Before applying a deep-review winner, revalidate catalog, generation, group
   signature, and winner membership.
6. Change sheet dismissal so it never silently applies a stale result. Prefer an
   explicit “Use recommendation” action; if automatic application is retained,
   run the same validation and no-op on mismatch.

Acceptance criteria:

- Review states follow unchanged membership across group-ID renumbering.
- Split, merged, or otherwise changed groups do not inherit unrelated states.
- Deep results disappear when catalog or membership changes.
- A stale sheet cannot apply a winner to a regrouped burst.

Tests:

- Renumber unchanged groups and verify state restoration by signature.
- Split and merge groups and verify unmatched states are dropped.
- Regroup or switch catalogs while a deep-review sheet is open and assert
  display/application rejects the stale result.

### Phase 5 — Align review queues and presets with real behavior (findings 6 and 8)

1. Keep singleton groups if they are needed to render every photo in burst mode,
   but define an analyzable/reviewable burst as a group with at least two files.
2. Skip singleton groups in ranking, `burstAnalysisResults`, review queue
   filters/counts, and deep-review entry points. Preserve their normal grid
   rendering without burst review controls.
3. Remove the `eyeDetail` preset from the selectable UI and persisted preset
   model for this fix, migrating a previously saved value to `headFace`.
   Implementing true eye localization can be tracked separately and the preset
   reintroduced only when it uses an eye region and distinct scoring window.
4. Update labels/help text and tests so no UI claims eye-specific analysis.

Acceptance criteria:

- Singleton photos never increase Needs Review, Deferred, or Reviewed counts.
- Every item reachable from a burst review queue has review actions.
- The application no longer presents head/face scoring as “Eye Detail.”

Tests:

- Cover catalogs containing only singletons and mixed singleton/multi-frame
  groups.
- Verify ranking and review counts exclude one-file groups.
- Verify decoding/migration of a stored `eyeDetail` preset selects `headFace`.

### Phase 6 — Make grid cache invalidation complete (finding 10)

1. Replace the partial render-cache key with deterministic signatures of:
   - every group ID and ordered member ID;
   - the complete ordered visible file ID list;
   - every score used by visible groups, including its file ID and value;
   - `maxScore`;
   - recommendation, manual-winner, and review-state fields used by rendering;
   - rating and review filters.
2. Prefer small version counters maintained by the owning models if profiling
   shows full hashing is expensive, but increment them only on relevant value
   changes—not merely count changes.
3. Keep cache rebuilding pure so key-equality tests can directly prove whether a
   render update is required.

Acceptance criteria:

- Changing a middle group member or middle visible file invalidates the cache.
- Changing a score value or `maxScore` updates best-frame names/percentages.
- Unchanged render inputs retain the existing cache.

Tests:

- Add focused key/rebuild tests for member replacement with equal counts,
  visible-file replacement with equal first/last IDs, score changes with equal
  score counts, `maxScore` changes, and manual-winner changes.

### Phase 7 — Integration verification and closeout

1. Run the targeted burst, similarity, sharpness, grid, cache, catalog lifecycle,
   and security-scope test suites after each phase.
2. Add one end-to-end regression scenario:
   analyze catalog A, change sensitivity, start deep review, switch to catalog B,
   wait for all old workers to finish, and verify B contains no state or cache
   artifacts from A.
3. Run the full Debug build and project test plan. Run Thread Sanitizer for the
   lifecycle/cancellation tests if the test target supports it.
4. Manually verify:
   - Analyze, Cancel, Reindex, and rapid sensitivity changes;
   - switching catalogs during each pipeline stage;
   - CLIP success and forced Vision fallback;
   - review-state persistence after selection/filter changes;
   - singleton-heavy catalogs;
   - deep-review dismissal after regrouping;
   - best-label refresh after rescoring.
5. Update this report as each finding closes with the implementing commit and
   regression-test name. Do not mark a finding closed until its acceptance
   criteria and tests pass.

### Suggested change grouping

To keep reviews and regressions manageable, land the work as these change sets:

1. task ownership, generation guards, and catalog reset;
2. structured similarity cancellation and transactional backend fallback;
3. cache/analysis signatures, immutable scope, and off-main serialization;
4. signature-based review/deep-review identity;
5. singleton policy and removal/migration of the misleading eye preset;
6. render-cache key correctness;
7. integration tests, manual verification, and report closeout.
