# RawCullSAM3 — SAM 3 Enhancement Ideas

This document outlines ideas for making deeper use of the Core AI SAM 3 model
that is already integrated into RawCullSAM3. Each idea includes a complexity
estimate, a rough timeframe, an assessment of the SAM 3 compute cost it
introduces, and any dependency on another SAM 3 feature listed here.

**Compute context.** SAM 3 inference currently takes roughly 150 ms – 1 500 ms
per image on Apple Silicon, depending on the chip tier and whether the model
has already been specialised on the device. The first call of a session is
always slower (model load + specialisation). Subsequent calls reuse the same
`CoreAISegmentationEngine` instance and results are cached in `SubjectMaskCache`
keyed on `(fileID, prompt, modelVersion, inputMaxSide)`, so the cost is paid at
most once per image per prompt per session.

---

## 1 — Subject-Presence Confidence Filter

**What.** Add a slider or threshold setting to the Rating / Filter panel that
hides images where the SAM 3 confidence score for the current prompt is below
a chosen percentage. A photographer culling bird-in-flight frames could
immediately discard shots where the subject is not visible or barely clipped.

**How.** The `SubjectSegmentationResult.confidence` value is already stored in
`SubjectMaskCache`. A filter pass over `filteredFiles` checks the cached
confidence; images without a cached result for the current prompt are shown by
default (no on-demand inference required just to filter).

**Compute impact.** Zero additional SAM 3 calls beyond what the cache already
holds. Filtering itself is CPU-only and instantaneous.

**Depends on.** Nothing — works with the existing on-demand mask flow.

**Complexity.** ⭐ Easy  
**Timeframe.** 1–2 days

---

## 2 — Subject Presence Badge on Grid Thumbnails

**What.** Display a small coloured badge on each grid thumbnail once a SAM 3
mask has been computed and cached for that image (similar to the sharpness score
badge). The badge could show the confidence percentage and use green / amber /
red colouring to give an at-a-glance subject-quality signal.

**How.** `SubjectMaskCache` is actor-isolated. Expose a lightweight read method
(or a `@Observable` wrapper) that the `GridThumbnailViewModel` can query without
triggering inference. Badges appear incrementally as results arrive.

**Compute impact.** No additional SAM 3 calls. Badges are driven by already-cached
results.

**Depends on.** Nothing beyond the existing on-demand mask flow, but becomes far
more useful if combined with **idea 4** (batch prefetch).

**Complexity.** ⭐ Easy  
**Timeframe.** 1–2 days

---

## 3 — Subject Bounding Box Export (Sidecar Metadata)

**What.** When saving culling results to the JSON sidecar, also write the SAM 3
mask bounding box (normalised `0–1` coordinates) for each image that has been
segmented. This lets downstream tools (DAM systems, print templates, social-crop
pipelines) know where the subject is without re-running inference.

**How.** After `SubjectSegmentationResult` is cached, compute the axis-aligned
bounding box of the non-zero mask pixels using a Metal/Accelerate pass (or a
tight CPU loop on the 8-bit alpha channel). Store it alongside the sharpness
score in `CullingScoringResult`.

**Compute impact.** Bounding-box extraction is a single image-scan — a few ms
per image at full resolution. SAM 3 itself is not re-run; results come from the
cache.

**Depends on.** Nothing, but the bounding box is most useful if **idea 4** has
already pre-populated the cache.

**Complexity.** ⭐⭐ Easy–Medium  
**Timeframe.** 2–3 days

---

## 4 — Background Batch Prefetch (Cache Warming)

**What.** When the user selects a prompt (or opens a catalog), kick off a
background task that runs SAM 3 on every image in the catalog sequentially,
filling `SubjectMaskCache`. Subsequent operations — filter, badge display,
sharpness weighting, histogram — can then consume cached results instantly.

**How.** A new `SubjectSegmentationActor.prefetchAll(files:prompt:)` method
iterates the file list, skipping already-cached entries and obeying Swift
cooperative cancellation. The `RawCullViewModel` starts this task after
indexing completes (or when the prompt picker changes). A progress indicator
mirrors the existing sharpness-scoring progress UI.

**Compute impact.** This is the highest-compute enhancement on the list. Running
SAM 3 on 500 images at 300 ms each = ~2.5 minutes wall time. The task runs at
`.background` priority so it does not compete with UI rendering. Users with many
images should be warned the first time. Already-cached images cost nothing.

**Depends on.** Nothing. It is a prerequisite for all the ideas below that
reference "cached SAM 3 result" to be cheap at use time.

**Complexity.** ⭐⭐ Easy–Medium  
**Timeframe.** 2–4 days

---

## 5 — Histogram Restricted to Subject Mask

**What.** Show a second histogram panel (or a toggle on the existing histogram
view) that computes exposure and tone distribution only for the pixels inside the
SAM 3 subject mask. This tells the photographer whether the *subject* is
correctly exposed, independent of a bright sky or dark background.

**How.** The existing histogram reads the full JPEG pixels. Add a masked variant
that multiplies each pixel's contribution by the mask's alpha channel before
accumulating bin counts. The mask image from `SubjectSegmentationResult.mask`
is already at display resolution.

**Compute impact.** Masked histogram accumulation is a Metal compute shader or
vDSP operation — single-digit milliseconds. No extra SAM 3 inference if the
mask is cached.

**Depends on.** **Idea 4** (batch prefetch) for the mask to be immediately
available when the histogram view opens; or on-demand mask fetch with a loading
state while SAM 3 runs.

**Complexity.** ⭐⭐⭐ Medium  
**Timeframe.** 3–5 days

---

## 6 — Multi-Prompt Auto-Classification

**What.** Run SAM 3 with every prompt in `SubjectSegmentationPrompt.allCases`
for each image, pick the prompt whose confidence is highest, and store that
label as the image's auto-detected subject type. This feeds automatically into
the saliency label used by the similarity penalty (`kSubjectMismatchPenalty`)
without requiring the user to pick the right prompt first.

**How.** A new `SubjectSegmentationActor.classify(image:fileID:fileURL:)` method
runs all prompts sequentially (reusing the single `CoreAISAM3Provider` instance),
collects confidence scores, and returns the best label. Results are stored
alongside existing `SaliencyInfo`.

**Compute impact.** Classification costs N × SAM 3 inference time where N is the
number of prompts (currently 6). On a fast chip that is ~900 ms – 9 000 ms per
image. Restrict to a single background task at `.low` priority, or run only on
the current burst group rather than the entire catalog.

**Depends on.** Nothing structurally, but it becomes far more practical when
combined with **idea 4** (prompts are pipelined in the same background pass).

**Complexity.** ⭐⭐⭐ Medium  
**Timeframe.** 4–6 days

---

## 7 — Subject-Weighted Sharpness Scoring

**What.** When computing the focus/sharpness score, apply the SAM 3 mask as a
spatial weight so that sharpness within the subject contributes more to the
final score than sharpness in the background. A photograph where the bird is
pin-sharp but the foreground grass is blurry should score higher than one where
the background tree is sharp but the bird is soft.

**How.** `FocusMaskEngine+Scoring.swift` produces per-pixel gradient magnitudes.
If a cached SAM 3 mask is available for the image and the current prompt, load
it and multiply the gradient map by the mask's alpha channel (normalised to
`0–1`) before computing the aggregate score. Fall back to the existing AF-guided
or saliency-guided region when no mask is available.

**Compute impact.** One SAM 3 inference per image if not already cached — adds
300 ms – 1 500 ms per image to the sharpness scoring pass. With **idea 4** in
place the cost drops to a few milliseconds (mask read from cache + Metal
multiply).

**Depends on.** **Idea 4** (batch prefetch) for acceptable scoring performance.
Without prefetch, sharpness scoring becomes significantly slower.

**Complexity.** ⭐⭐⭐ Medium  
**Timeframe.** 4–7 days

---

## 8 — Subject-Masked Similarity Embeddings

**What.** When computing the `VNFeaturePrintObservation` for similarity search,
crop the decoded thumbnail to the SAM 3 mask bounding box (or apply the mask
alpha) before sending it through Vision. Two photographs of the same bird
against different backgrounds would then score as very similar; two photographs
of a bird and a person would score as very different, without needing the
saliency mismatch penalty heuristic.

**How.** In `SimilarityScoringModel.computeEmbedding(url:maxPixelSize:)`, after
decoding the thumbnail, check whether a cached SAM 3 mask is available (via a
shared `SubjectMaskCache` reference). If so, composite the thumbnail over a
black background using the mask, then compute the feature print on the
masked image.

**Compute impact.** If the mask is already cached the added cost is one
compositing pass in CoreImage (~5 ms). Without the cache this forces a SAM 3
inference per image during the similarity indexing pass, adding 300 ms – 1 500 ms
per image.

**Depends on.** **Idea 4** (batch prefetch) for the masks to be available during
similarity indexing without triggering live inference; **idea 6**
(auto-classification) to determine which prompt produced the authoritative mask.

**Complexity.** ⭐⭐⭐⭐ Medium–Hard  
**Timeframe.** 5–8 days

---

## 9 — Smart Crop Suggestion Overlay

**What.** In the zoom view, overlay rule-of-thirds or golden-ratio crop guides
anchored to the SAM 3 mask centroid and bounding box. The UI suggests the tightest
crop that keeps the subject comfortably inside the frame, respecting common
aspect ratios (1:1, 4:3, 16:9, 4:5, 3:2).

**How.** After a mask is generated, compute its tight bounding box and centroid.
Implement a `CropSuggestionEngine` that enumerates candidate crop rectangles
(centring on the subject, biased to rule-of-thirds intersection points) and
scores them by subject coverage and proximity to common aspect ratios. Render the
top three suggestions as dashed overlays in `ZoomOverlayView`.

**Compute impact.** Crop computation is pure geometry — negligible CPU. SAM 3
inference is already triggered by the existing mask overlay workflow; no extra
model calls are needed.

**Depends on.** The standard on-demand SAM 3 mask (already available in the zoom
view). No dependency on other ideas, but **idea 3** (bounding box export) shares
the same geometry computation and could be built alongside this.

**Complexity.** ⭐⭐⭐⭐ Medium–Hard  
**Timeframe.** 5–10 days

---

## 10 — Background Stylisation (Subject-Isolated Blur / Tone)

**What.** In the zoom preview, apply a Metal or CoreImage effect to the
background pixels (those where the SAM 3 mask alpha is low) — for example a
Gaussian blur, a desaturation, or a tone curve — while leaving the subject
pixels untouched. This gives the photographer a simulated shallow-depth-of-field
look during culling to judge subject isolation.

**How.** Extend `Kernels.ci.metal` with a mask-blended blur kernel that takes
the display image and the SAM 3 mask as inputs. Apply with a tunable blur radius
(0 = off, up to ~40 pt for a strong look). The result feeds the existing
`ZoomOverlayView` image pipeline.

**Compute impact.** One SAM 3 inference on demand (already part of the existing
mask-display workflow). The Metal blur pass runs entirely on the GPU and adds
< 10 ms per frame. The render is static (not real-time video), so cost is
negligible after the mask is ready.

**Depends on.** The standard on-demand SAM 3 mask. Optionally benefits from
**idea 4** (batch prefetch) so the blur effect appears immediately when the
zoom view opens.

**Complexity.** ⭐⭐⭐⭐ Medium–Hard  
**Timeframe.** 5–10 days

---

## 11 — Best-in-Burst by Subject Sharpness

**What.** After burst groups are identified by the similarity model, run SAM 3
once per group member and compute sharpness only within the subject mask. Auto-
select (and optionally auto-rate) the frame with the highest subject-weighted
sharpness score. This is the end-to-end automated culling workflow: the model
picks the sharpest, in-focus frame of the subject from each burst.

**How.** A new `BurstSubjectCullingEngine` coordinates the pipeline:
1. Retrieve burst group membership from `SimilarityScoringModel`.
2. For each group, fetch or request SAM 3 masks for all members.
3. Compute subject-weighted sharpness scores (reusing **idea 7** logic).
4. Return the best-scored frame per group.
5. Optionally apply a star rating to winners and reject losers.

**Compute impact.** The heaviest feature on this list if run without cached
results. For a 500-image catalog with 10-shot bursts, that is 500 SAM 3
inferences + 500 sharpness passes. With **ideas 4 and 7** already in place
the incremental cost is just the group aggregation logic — essentially free.

**Depends on.** **Idea 4** (batch prefetch), **idea 7** (subject-weighted
sharpness), and the existing burst grouping in `SimilarityScoringModel`. This
is the most dependent feature on the list and should be implemented last.

**Complexity.** ⭐⭐⭐⭐⭐ Hard  
**Timeframe.** 2–4 weeks (including integration testing across burst edge cases)

---

## Dependency Graph

```
Idea 4 (Batch Prefetch)
├── Idea 2 (Grid Badges)       — benefits from cache, not required
├── Idea 1 (Confidence Filter) — benefits from cache, not required
├── Idea 3 (Sidecar Export)    — benefits from cache, not required
├── Idea 5 (Masked Histogram)  — required for instant UX
├── Idea 6 (Auto-Classification) — not required but practical
├── Idea 7 (Subject-Weighted Sharpness)  — required for fast scoring
│   └── Idea 11 (Best-in-Burst)          — requires idea 7
├── Idea 8 (Masked Similarity)           — requires idea 4 & idea 6
│   └── Idea 11 (Best-in-Burst)          — requires idea 8 (optional)
└── Idea 10 (Background Blur)  — benefits from cache, not required

Idea 9 (Smart Crop) — independent, only needs on-demand mask
Idea 3 (Sidecar Export) — can share bounding-box logic with Idea 9
```

---

## Summary Table

| # | Feature | Complexity | Timeframe | Extra SAM 3 cost | Depends on |
|---|---------|-----------|-----------|-----------------|-----------|
| 1 | Confidence Filter | ⭐ Easy | 1–2 days | None (cache only) | — |
| 2 | Grid Badges | ⭐ Easy | 1–2 days | None (cache only) | — |
| 3 | Sidecar BBox Export | ⭐⭐ Easy–Medium | 2–3 days | None (cache only) | — |
| 4 | Batch Prefetch | ⭐⭐ Easy–Medium | 2–4 days | Full catalog × 1 prompt | — |
| 5 | Masked Histogram | ⭐⭐⭐ Medium | 3–5 days | None w/ cache | #4 |
| 6 | Auto-Classification | ⭐⭐⭐ Medium | 4–6 days | Full catalog × N prompts | #4 |
| 7 | Subject-Weighted Sharpness | ⭐⭐⭐ Medium | 4–7 days | None w/ cache | #4 |
| 8 | Masked Similarity | ⭐⭐⭐⭐ Medium–Hard | 5–8 days | None w/ cache | #4, #6 |
| 9 | Smart Crop Suggestion | ⭐⭐⭐⭐ Medium–Hard | 5–10 days | None (on-demand mask) | — |
| 10 | Background Blur | ⭐⭐⭐⭐ Medium–Hard | 5–10 days | None (on-demand mask) | — |
| 11 | Best-in-Burst Subject Pick | ⭐⭐⭐⭐⭐ Hard | 2–4 weeks | None w/ cache | #4, #7 |

**Recommended build order**: 1 → 2 → 4 → 3 → 5 → 7 → 6 → 9 → 10 → 8 → 11
