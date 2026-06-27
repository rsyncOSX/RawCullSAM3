That's enough to give a thorough review. Let me read a couple more targeted files before writing it up.This is a lot to work with. Here's the full review:

---

## AI pipeline review — RawCullSAM3

### SAM3 integration

**`CoreAISAM3Provider`** is well-structured. The actor isolation is correct, the `@retroactive @unchecked Sendable` conformances are appropriately commented, and the lazy model loading with a cached `LoadedSAM3Model` is the right pattern — you don't want to reload the model on every image.

The mask decoding pipeline is notably good. `bestQueryIndex` correctly handles both `predictedScores` (direct confidence) and `predictedLogits` (sigmoid-converted) and multiplies in the `presenceLogit` when available — that's the right interpretation of SAM3's output format. The `fillBilinearMaskPixels` with smooth sigmoid feathering (`smoothMaskAlpha`) is a nice touch that gives cleaner mask edges than a hard threshold would.

One concern: the flat-layout shim in `resourcesURLForImageSegmenter` — the part that creates a temp directory in `FileManager.temporaryDirectory`, copies files, and creates a symlink to the `.aimodel` — is fragile. If `removeItem` at the top fails (e.g. permissions, or the directory is in use), the function throws and model loading fails with an opaque error. The temp dir is also recreated on every cold load, which is fine but noisy. Worth wrapping more defensively or checking the exact failure mode before removing.

**`SubjectSegmentationActor`** — the stale-response check via `activeRequestID` is a clean pattern for racing async requests. The three-tier cache (in-memory `SubjectMaskCache` → disk `SAM3MaskDiskCache`) is exactly right. One subtlety: `cacheKey()` spawns a `Task.detached` to read file attributes, which means every cache lookup involves a detached task for a file system stat. For a warm cache during browsing this is constant overhead even when you know the file hasn't changed. Worth considering whether the `fileSize`/`modificationDate` portion of the key could be captured once per file at catalog scan time and passed in rather than re-statted on every segment call.

**`SAM3MaskDiskCache`** is solid. Using MD5 of the canonical key string as the filename is fine for this purpose (not security-sensitive, just cache disambiguation). The `metadataFileExists()` fast-path returning a synchronous bool before spawning the full validity check is a good optimization for large catalogs. The `.atomic` writes are correct. One thing to note: the cache key includes `modelVersion` = `"coreai-sam3-local"`, which is a constant string. If you ever ship a second model variant you'll need to change this string to invalidate the old cache — worth making that more intentional than a hardcoded literal.

**`SAM3MaskInventoryEntry`** is clean. The geometry helpers (coverage, bounding box, centroid) operate on the alpha plane correctly. The `isFresh` comparison using source vs. cache modification dates is the right invalidation strategy.

---

### The mask → sharpness integration (the important part)

This is far more complete than the README suggests. The SAM3 mask is genuinely wired into the scoring pipeline in `FocusMaskEngine+Scoring.swift` and it's doing sophisticated things:

**`analyzeSAMSubjectMask`** samples the Laplacian red channel only within the mask alpha, computes `robustTailScore` on those samples, and also reports `microContrast` and `coverage`. This is exactly the right approach — you're scoring sharpness on precisely the subject pixels, not the whole frame.

**`analyzeDeepAISubjectMask`** goes further with interior erosion (the `erosionRadius = max(1, min(w,h)/90)` approach avoids sampling the feathered mask boundary), local patch scanning within the subject bounding box, and an AF proximity bonus in the patch composite score. The background dominance penalty (`fullScore > max(final * 1.45, final + 0.04)`) is smart — catching cases where a sharp background is masking a soft subject.

The **blending logic** in `computeSharpnessAnalysis` is nuanced:
```
// When AF is inside the SAM mask:
broadSubjectScore = sam * 0.55 + af * 0.45

// When AF is outside:
broadSubjectScore = sam * 0.70 + af * 0.15 + saliency * 0.15

// No AF:
broadSubjectScore = sam * 0.80 + saliency * 0.20
```

This correctly privileges SAM3 as the primary signal while keeping AF as a strong secondary when it confirms the subject. The `afInsideSAMMask` boolean doing this case-splitting is the key insight — it answers "did the camera actually focus where the mask says the subject is?"

The `localBlendWeight` bump (`0.35` when AF is inside the SAM mask vs `0.25` otherwise) giving more weight to local patch scoring when the AF point confirms the subject is a nice refinement.

**One concern** in `computeSharpnessAnalysis`: the SAM mask analysis path allocates a full `[Float]` of all `pixelCount * 4` Laplacian values just to pass into `analyzeSAMSubjectMask`:
```swift
let samMaskAnalysis: SAMSubjectMaskAnalysis? = if let subjectMask {
    Self.analyzeSAMSubjectMask(
        laplacianRedValues: (0 ..< pixelCount).map { redAt($0) },
        ...
```
This creates a temporary `[Float]` of `width * height` elements that duplicates data already in `rgba`. For a 4320px-bounded image that's `4320² = ~18.7M` floats = ~75MB allocated and thrown away on every scored frame. The function only uses the red channel anyway. Worth either striding directly over `rgba` with step 4, or extracting the red plane once and reusing it for both the full-frame and SAM analyses.

---

### CLIP integration

CLIP is much more complete than I expected from our earlier conversation. You've built:

- `CoreAICLIPProvider` — full Core AI NDArray inference pipeline with CHW preprocessing, correct ImageNet normalization (`mean=[0.485, 0.456, 0.406]`... wait, actually `[0.48145466, 0.4578275, 0.40821073]` — that's the OpenAI CLIP normalization, correct), L2-normalized output embeddings, and zero-shot label classification via batched text encoding.
- `SimilarityScoringModel` — dual-backend (CLIP / `VNFeaturePrintObservation`) with graceful fallback, burst grouping via sequential distance clustering, saliency mismatch penalty in ranking, and bounded concurrent indexing (`maxConcurrentIndexingTasks = 4`).

The CLIP zero-shot classification labels are wildlife-appropriate (bird, animal, deer, insect, flower). The softmax conversion in `bestLabel` for confidence is correct.

**On the earlier CLIP discussion**: you've validated my skepticism about CLIP for *within-burst* sharpness scoring — it's not used there at all. Instead CLIP is used purely for inter-image similarity and burst grouping, which is exactly where it makes sense. The `VNFeaturePrintObservation` fallback when CLIP isn't installed is the right default.

One design question: `CoreAICLIPProvider.loadLabelEmbeddings` encodes all zero-shot text prompts and caches the embeddings in memory. This is called lazily on first `imageAnalysis` call. For the similarity use case (pure image embeddings) `loadLabelEmbeddings` is never called, which is efficient. But if someone opens Settings > AI and triggers classification on a large catalog, the label embeddings will be computed once and held in the actor indefinitely. Not a problem in practice but worth noting.

The `requiresVisionFallback` check — falling back to Vision for the *entire* file list if CLIP indexing was incomplete for any file — is conservative but correct. A partial CLIP index would mean mixed embedding types, which breaks distance computation since `distance(.clip, .vision)` returns `nil`.

---

### Overall assessment

The loop is closed. This isn't "AI-assisted viewing" — it's a proper AI-assisted culling pipeline where SAM3 is the primary sharpness evidence source, not a decoration on top of the existing saliency approach. The architecture is production-quality. The main things I'd look at next:

1. The 75MB temporary array in `computeSharpnessAnalysis` — the red-channel extraction duplication
2. The per-segment file stat in `SubjectSegmentationActor.cacheKey()` — could be lifted to catalog scan time
3. The hardcoded `"coreai-sam3-local"` model version string — make it explicit and tied to something that changes when the model does
4. The temp directory shim in `resourcesURLForImageSegmenter` — more defensive error handling around the remove step
