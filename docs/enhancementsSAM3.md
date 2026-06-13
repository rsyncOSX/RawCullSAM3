# RawCullSAM3 — SAM 3 Enhancement Ideas

This document outlines ideas for making deeper use of the Core AI SAM 3 model
that is already integrated into RawCullSAM3. Each idea includes a complexity
estimate, a rough timeframe, an assessment of the SAM 3 compute cost it
introduces, and any dependency on another SAM 3 feature listed here.

## 2026-06-12 Status Update

RawCull now has the two foundation pieces that this document previously treated
as future work:

- **Persistent SAM 3 mask disk cache** is implemented via `SAM3MaskDiskCache`.
  Masks are stored under `~/Library/Caches/no.blogspot.RawCull/SAM3Masks/` with
  source-file identity metadata, so already-generated masks survive RawCull
  restarts.
- **Full-catalog SAM 3 mask creation** is implemented as the bundled
  `RawCullSAM3MaskBuilder` helper process. RawCull launches the helper, the
  helper scans the selected catalog, writes masks into the same disk cache, then
  RawCull restarts to reclaim memory.

This changes the strategic order. The first priority is no longer "how do we
get masks?" but **how do we turn cached masks into culling signal without
running SAM 3 again**.

**Compute context.** SAM 3 inference currently takes roughly 150 ms – 1 500 ms
per image on Apple Silicon, depending on the chip tier and whether the model
has already been specialised on the device. The first call of a session is
always slower (model load + specialisation). Subsequent calls reuse the same
`CoreAISegmentationEngine` instance and results are cached in `SubjectMaskCache`
keyed on `(fileID, prompt, modelVersion, inputMaxSide)`, so the cost is paid at
most once per image per prompt per session.

With the helper and disk cache in place, the preferred architecture for any
feature below is:

```text
Create masks once in RawCullSAM3MaskBuilder
  -> read cached masks in RawCull
  -> compute lightweight geometry / quality / UI signals
  -> never invoke SAM 3 from interactive browsing unless explicitly requested
```

---

## Recommended Next Wave — Turn Masks Into Culling Signals

These are the most valuable next steps now that catalog-wide mask generation is
working.

### A — Mask Inventory and Coverage Metadata

**Status.** Implemented foundation.

**What.** After opening a catalog, scan the SAM 3 disk cache and build a
lightweight per-file mask inventory: `hasMask`, `confidence`, `coverage`,
`boundingBox`, `centroid`, and `source freshness`.

**Why.** Many downstream features need the same cheap facts. Computing them once
prevents every view from decoding PNG masks independently.

**How.** Add a `SAM3MaskCatalogIndex` actor that iterates the current
`FileItem`s, calls `SAM3SubjectMaskCacheReader.loadCachedMask`, computes mask
geometry, and publishes an observable dictionary keyed by `FileItem.ID`.

**Complexity.** ⭐⭐ Easy-Medium  
**Timeframe.** 2-3 days

### B — Subject Quality Badge

**Status.** Implemented first version.

**What.** Add a compact badge to thumbnails and comparison panes showing whether
the cached subject mask is usable. The visible badge is intentionally based on
mask geometry and freshness rather than the raw SAM 3 confidence score.

**Why.** This is the first "AI assisted culling" feature users can see without
changing scoring logic. It answers: "Did SAM 3 find a usable subject here?"

**How.** Use the mask inventory. Color badge:

- Green `SAM`: cached mask exists, coverage is reasonable, bounding box is
  non-empty, the cache is fresh, and the subject is not clipped at the frame edge.
- Amber `SAM ?`: cached mask exists but has a caution such as low/broad coverage,
  stale cache metadata, or near-edge clipping.
- Red `SAM --`: no cached mask, empty bounding box, near-empty coverage, or
  extremely broad coverage.

The SAM 3 model confidence score remains available in the badge help text as
diagnostic metadata, but it should not be treated as the user-facing mask quality
grade. A visually useful mask can have low model confidence, especially for
low-contrast subjects, clipped subjects, or generic prompts.

**Complexity.** ⭐⭐ Easy-Medium  
**Timeframe.** 2-4 days

### C — Subject Geometry Review Queue

**What.** Add a review filter for images where the subject is too small, clipped,
off-center, or absent. This is useful before sharpness scoring: it quickly
separates "no usable subject" frames from real candidates.

**How.** Extend the rating/filter controls with a "Subject" segment:
`All`, `Good subject`, `Weak/missing`, `Clipped`, `Small subject`.

**Complexity.** ⭐⭐ Easy-Medium  
**Timeframe.** 3-4 days

### D — Subject-Weighted Sharpness

**What.** Use the cached SAM 3 mask as the primary weighting region for
sharpness scoring, instead of relying mostly on saliency/AF heuristics.

**Why.** This is likely the highest-value culling improvement: the best image in
a burst should be the one where the subject is sharp, not where the background
or foreground has the most contrast.

**How.** Feed the cached mask into `FocusMaskEngine+Scoring.swift` as an optional
subject weight. Fall back to the existing scoring path when no mask exists.

**Complexity.** ⭐⭐⭐ Medium  
**Timeframe.** 4-7 days

### E — Best-in-Burst by Subject Sharpness

**What.** In burst groups, pick the winner by subject-weighted sharpness and
subject geometry quality.

**Why.** This is the practical endgame for AI-supported RawCull: automatically
suggest the frame where the subject is present, not clipped, and sharp.

**How.** Combine existing burst groups, the mask inventory, and
subject-weighted sharpness. Keep the first version advisory: show a suggested
winner badge before auto-rating/rejecting anything.

**Complexity.** ⭐⭐⭐⭐ Medium-Hard  
**Timeframe.** 1-2 weeks

---

## 1 — Subject Geometry / Usability Filter

**What.** Add a filter to the Rating / Filter panel that hides or isolates images
where the cached SAM 3 mask is missing, unusable, clipped, too small, or too
broad. Raw SAM 3 confidence can remain visible as diagnostic metadata, but it
should not be the primary filter gate.

**How.** Use the mask inventory from **A** rather than querying the model or
decoding masks per view refresh. A filter pass over `filteredFiles` checks
cached geometry and freshness; images without a cached result for the current
prompt can be shown by default or grouped under "missing mask".

**Compute impact.** Zero additional SAM 3 calls beyond what the cache already
holds. Filtering itself is CPU-only and instantaneous.

**Depends on.** **A** for fast per-file geometry and freshness metadata.

**Complexity.** ⭐ Easy  
**Timeframe.** 1–2 days

---

## 2 — Subject Presence Badge on Grid Thumbnails

**What.** Display a small coloured badge on each grid thumbnail once a SAM 3
mask has been computed and cached for that image (similar to the sharpness score
badge). The badge should show mask usability, not the raw confidence percentage:
green `SAM`, amber `SAM ?`, or red `SAM --`.

**How.** Let `GridThumbnailViewModel` read published mask inventory state rather
than calling the segmentation actor. Badges appear incrementally as the catalog
index loads cached masks. Keep model confidence in help text only.

**Compute impact.** No additional SAM 3 calls. Badges are driven by already-cached
results.

**Depends on.** Best implemented through the mask inventory in **A**, with masks
created by the helper in **idea 4**.

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

**Depends on.** Best implemented through the mask inventory in **A**, because
bounding box extraction is a shared geometry calculation.

**Complexity.** ⭐⭐ Easy–Medium  
**Timeframe.** 2–3 days

---

## 4 — Helper-Based Catalog Mask Creation

**Status.** Implemented foundation.

**What.** RawCull can launch the bundled `RawCullSAM3MaskBuilder` helper process
to scan the selected catalog and create SAM 3 masks outside the main app
process. The helper writes directly into the same `SAM3MaskDiskCache` format
that RawCull reads. When the helper finishes successfully, RawCull restarts so
memory returns to a clean process baseline.

**How.** RawCull owns the UI and launches the helper with a JSON request
containing the catalog bookmark, model resource path, cache directory, and
RawCull app path. The helper reports newline-delimited JSON progress events over
stdout. RawCull displays a compact blocking progress overlay and can terminate
the helper on cancel.

**Compute impact.** Full catalog × 1 prompt, but the expensive work happens in a
separate process. Already-cached images are skipped, and the resulting masks are
reused across RawCull launches.

**Depends on.** The persistent disk cache, which is also implemented.

**Complexity.** Implemented  
**Timeframe.** Implemented

**Future refinements.**
- Add "current filter only" and "selected files only" helper modes.
- Persist failed-file details so the progress UI can show exactly which files
  did not produce masks.
- Allow the helper to resume only missing/stale masks without rescanning all
  files when the catalog is very large.

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

**Depends on.** **A** for immediate mask geometry and cache lookup. If no mask
exists, the UI can show a missing-mask state rather than launching SAM 3 during
histogram rendering.

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

**Depends on.** Nothing structurally, but it should be a later helper mode
because it multiplies helper work by the number of prompts.

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

**Compute impact.** With helper-created masks, the scoring pass only pays for a
mask read plus a Metal/Accelerate weighting step. If no mask exists, fall back to
the existing sharpness path instead of launching SAM 3 during scoring.

**Depends on.** **A** for cheap mask lookup and geometry metadata.

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
decoding the thumbnail, check whether a cached SAM 3 mask is available through
the mask inventory/cache-reader path. If so, composite the thumbnail over a
black background using the mask, then compute the feature print on the masked
image.

**Compute impact.** If the mask is already cached the added cost is one
compositing pass in CoreImage (~5 ms). Without the cache this forces a SAM 3
inference per image during the similarity indexing pass, adding 300 ms – 1 500 ms
per image.

**Depends on.** **A** for mask lookup during similarity indexing; **idea 6**
(auto-classification) only if RawCull needs to decide between multiple prompt
types automatically.

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

**Depends on.** **A** for instant cache-backed masks. The existing on-demand
mask view can remain as a fallback for files that have not been processed by the
helper yet.

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

**Compute impact.** With helper-created masks and subject-weighted sharpness
already cached, the incremental cost is just group aggregation. If masks are
missing, skip those files or mark the group as incomplete rather than launching
bulk SAM 3 inference from the main app.

**Depends on.** **A** (mask inventory), **idea 7** (subject-weighted sharpness),
and the existing burst grouping in `SimilarityScoringModel`. This is the most
dependent feature on the list and should be implemented after the advisory
signals prove useful.

**Complexity.** ⭐⭐⭐⭐⭐ Hard  
**Timeframe.** 2–4 weeks (including integration testing across burst edge cases)

---

## Dependency Graph

```text
Implemented foundation
├── Idea 12 (Persistent Disk Mask Cache)
└── Idea 4 (Helper-Based Catalog Mask Creation)

Next-wave mask inventory
├── A (Mask Inventory and Coverage Metadata)
│   ├── B / Idea 2 (Subject Quality Badge)
│   ├── C / Idea 1 (Subject Review Filters)
│   ├── Idea 3 (Sidecar Bounding Box Export)
│   ├── Idea 5 (Masked Histogram)
│   ├── Idea 9 (Smart Crop Suggestions)
│   └── Idea 10 (Background Isolation Effects)
└── D / Idea 7 (Subject-Weighted Sharpness)
    └── E / Idea 11 (Best-in-Burst Subject Pick)

Idea 6 (Auto-Classification) is optional and expensive because it runs multiple
prompts per image. It should wait until single-prompt mask usage is clearly
valuable.

Idea 8 (Subject-Masked Similarity) is powerful but touches indexing behavior.
It should come after mask inventory and subject-weighted sharpness are stable.
```

---

## Summary Table

| # | Feature | Status | Complexity | Timeframe | Extra SAM 3 cost | Depends on |
|---|---------|--------|-----------|-----------|-----------------|-----------|
| A | Mask Inventory / Coverage Metadata | Implemented | ⭐⭐ Easy–Medium | 2–3 days | None (cache only) | #12 |
| B / 2 | Subject Quality Badge | Implemented first version | ⭐⭐ Easy–Medium | 2–4 days | None (cache only) | A |
| C / 1 | Subject Review Filters | Proposed next | ⭐⭐ Easy–Medium | 3–4 days | None (cache only) | A |
| 3 | Sidecar BBox Export | Proposed | ⭐⭐ Easy–Medium | 2–3 days | None (cache only) | A |
| 4 | Helper Catalog Mask Creation | Implemented | — | — | Full catalog × 1 prompt | #12 |
| 5 | Masked Histogram | Proposed | ⭐⭐⭐ Medium | 3–5 days | None w/ cache | A |
| 6 | Auto-Classification | Later | ⭐⭐⭐ Medium | 4–6 days | Full catalog × N prompts | #4 |
| D / 7 | Subject-Weighted Sharpness | Proposed next | ⭐⭐⭐ Medium | 4–7 days | None w/ cache | A |
| 8 | Masked Similarity | Later | ⭐⭐⭐⭐ Medium–Hard | 5–8 days | None w/ cache | A, #6 optional |
| 9 | Smart Crop Suggestion | Proposed | ⭐⭐⭐⭐ Medium–Hard | 5–10 days | None w/ cache | A |
| 10 | Background Blur | Proposed | ⭐⭐⭐⭐ Medium–Hard | 5–10 days | None w/ cache | A |
| E / 11 | Best-in-Burst Subject Pick | Later | ⭐⭐⭐⭐ Medium–Hard | 1–2 weeks | None w/ cache | A, D |
| 12 | Persistent Disk Mask Cache | Implemented | — | — | None (eliminates re-inference) | — |

**Recommended build order**: A → B → C → D → E. After those are useful in
daily culling, add 3, 5, 9, and 10 as supporting features. Leave 6 and 8 until
the single-prompt workflow has proven its value, because they are broader and
more expensive changes.

---

## On SAM 3's Core Role and the Mask-as-Output Principle

SAM 3's primary and most important function is **producing subject masks** — binary or alpha-channel images that tell every other part of the app which pixels belong to the subject and which belong to the background. Everything else in this document (filtering, histograms, sharpness scoring, similarity search, crop suggestions) is downstream of that mask. The mask is the result; SAM 3 inference is the cost paid to obtain it.

This leads directly to a strategic observation: because the mask is the *output*
and inference is the *cost*, any scheme that eliminates redundant inference
multiplies the value of all downstream features. RawCull now has both layers:
the in-session `SubjectMaskCache` for fast reuse during one launch, and the
persistent `SAM3MaskDiskCache` for reuse across launches. That means the next
features should treat masks as durable catalog data, not temporary UI state.

---

## 12 — Persistent On-Disk SAM 3 Mask Cache

**Status.** Implemented foundation.

**What.** Each computed mask is written to disk inside
`~/Library/Caches/no.blogspot.RawCull/SAM3Masks/` with metadata for the prompt,
confidence, model version, input size, and source-file identity. On subsequent
launches, RawCull can read the mask from disk in milliseconds instead of
re-running SAM 3 inference.

**Why this matters beyond idea 4.** The helper process fills the disk cache once;
the disk cache makes that investment permanent until the source file changes or
the entry is pruned. This is what makes the new feature direction practical:
filters, badges, sharpness, histograms, crops, and burst suggestions can all be
computed from cached masks without waking the model.

**How it works.** `SAM3MaskDiskCache` follows the same broad pattern as the
other RawCull disk caches:

1. **Cache key:** based on the source file identity, prompt, model version, and
   input max side so existing cached masks remain compatible with RawCull and
   helper-created masks are immediately readable after restart.

2. **On inference completion:** the mask is encoded losslessly, written to the
   cache, and paired with source-file metadata.

3. **On cache lookup:** RawCull checks disk before launching inference. If the
   disk entry is valid, the mask is reconstructed and can be used immediately.

4. **Staleness detection:** if the source file has changed, the entry is ignored
   and a fresh mask can be generated.

5. **Size management:** the cache can participate in the same pruning and
   removal flows as the other RawCull caches.

**Storage cost.** A SAM 3 mask at typical output resolution (e.g. 1 000 × 667 px
single-channel) compresses to roughly 5–30 KB as a lossless PNG (smooth alpha
gradients compress well). For a catalog of 500 images × 6 prompts = 3 000 masks
× 20 KB average ≈ **60 MB**. That is comparable to the existing thumbnail disk
cache and negligible on any modern Mac.

**Compute impact.** PNG encoding of a mask is a single CPU pass — a few
milliseconds at most. The disk write happens at background priority and does not
block the UI. All downstream features (ideas 1–11) that currently state "None
w/ cache" gain an additional benefit: the cache can be populated by the helper
before the user starts browsing or scoring the catalog.

**Integration points.**
- `SubjectSegmentationActor` writes masks after successful inference.
- `SAM3SubjectMaskCacheReader` gives RawCull and tests a compatible read path.
- `RawCullSAM3MaskBuilder` writes the same cache entries as the main app.

**Depends on.** Nothing. It is the base layer for every idea that consumes a
cached mask.

**Complexity.** Implemented  
**Timeframe.** Implemented
