# make build-release
# make install-sam3-model
# sudo ditto "$(make print-release-app)" "/Applications/RawCullSAM3.app"
# open "/Applications/RawCullSAM3.app"

APP ?= RawCullSAM3
SCHEME ?= RawCullSAM3
PROJECT ?= RawCullSAM3.xcodeproj

DERIVED_DATA_ROOT ?= $(HOME)/Library/Developer/Xcode/DerivedData

TEST_DESTINATION = platform=macOS
XCODE_TEST_FLAGS = -project $(PROJECT) -scheme $(SCHEME) -destination '$(TEST_DESTINATION)' -onlyUsePackageVersionsFromResolvedFile
SMOKE_ONLY_TESTING = \
	'-only-testing:RawCullSAM3Tests/SimilarityDistanceOrderingTests/`rankSimilar returns nearest image first`()' \
	'-only-testing:RawCullSAM3Tests/SimilarityDistanceOrderingTests/`anchor is excluded from distances`()' \
	'-only-testing:RawCullSAM3Tests/SimilarityEmptyStateTests/`rankSimilar with unknown anchor clears state`()' \
	'-only-testing:RawCullSAM3Tests/SimilarityEmptyStateTests/`indexFiles with empty array leaves model unchanged`()' \
	'-only-testing:RawCullSAM3Tests/SimilarityEmptyStateTests/`initial sortBySimilarity is false`()' \
	'-only-testing:RawCullSAM3Tests/SimilaritySubjectMismatchTests/`subject mismatch increases distance`()' \
	'-only-testing:RawCullSAM3Tests/SimilarityCancellationTests/`cancelIndexing resets progress state`()' \
	'-only-testing:RawCullSAM3Tests/SimilarityCancellationTests/`reset clears all similarity state`()' \
	'-only-testing:RawCullSAM3Tests/SharpnessScoringTests/`max score small set uses maximum not minimum`()' \
	'-only-testing:RawCullSAM3Tests/SharpnessScoringTests/`max score single zero score has 1e-6 floor`()' \
	'-only-testing:RawCullSAM3Tests/SharpnessScoringTests/`max score large set uses P 90`()' \
	'-only-testing:RawCullSAM3Tests/SharpnessScoringTests/`sharpness label maps threshold boundaries`()' \
	'-only-testing:RawCullSAM3Tests/SharpnessScoringTests/`sharpness label clamps and handles invalid denominator`()' \
	'-only-testing:RawCullSAM3Tests/SharpnessScoringTests/`RAW demosaic scoring source caps concurrency and keeps embedded default`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`robust tail score empty returns nil`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`robust tail score uniform returns zero`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`robust tail score dense edges scores higher than sparse`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`robust tail score dense edges full density factor`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`robust tail score sparse edges scores low`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`robust tail score is scale proportional`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`micro contrast empty returns zero`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`micro contrast uniform returns zero`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`micro contrast ignores non finite`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`micro contrast alternating known variance`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`adaptive AF threshold keeps low contrast local detail reachable`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`adaptive saliency threshold rises for broad high contrast edges`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`adaptive AF threshold is capped so strong body edges do not hide AF detail`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection prefers AF when strongest`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection prefers AF center when eye patch is strongest`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection uses AF neighborhood when center is weak`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection keeps wildlife AF when nearly strongest`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection uses saliency when AF is absent`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection keeps saliency when AF local scores are weak`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`focus evidence selection falls back to global without subject evidence`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`AF local rect stays constrained around focus point`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`AF pixel center matches overlay normalized coordinates`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`resolution scaling uses longest side regardless of orientation`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`visibility relaxation lowers threshold and reports coverage`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`generic decode normalization produces sRGB eight bit RGBA`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`scoring size normalization clamps legacy and oversized values`(value:expected:)' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`conservative subject score keeps broad score dominant`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`conservative subject score preserves broad fallback without patches`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`saliency selection prefers AF overlap over confidence`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`saliency selection is deterministic without AF`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`saliency selection reports empty fallback`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`scoring signature ignores visual controls and tracks score controls`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`scoring signature invalidates for every score affecting field and policy version`()' \
	'-only-testing:RawCullSAM3Tests/FocusNumericHelperTests/`applying visual calibration does not change scoring signature`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`AF centered patch wins over slightly stronger distant patch`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`AF distant patch wins when detail exceeds override`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`saliency interior patch beats silhouette border`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`global evidence uses medium confidence when measurable`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`no viable patch is low confidence`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`diagnostics report visualized patch and AF distance`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`eye head heuristic rewards compact ring detail over linear edge`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`AF anchored heuristic penalizes lower patch beyond head window`()' \
	'-only-testing:RawCullSAM3Tests/FocusEvidencePatchOverlayTests/`saliency heuristic does not invent below AF penalty`()' \
	'-only-testing:RawCullSAM3Tests/BurstRankingEngineTests/`burst relative sharpness can outweigh subject metadata when detail clearly leads`()' \
	'-only-testing:RawCullSAM3Tests/BurstRankingEngineTests/`burst relative sharpness is omitted for tiny sharpness spread`()' \
	'-only-testing:RawCullSAM3Tests/BurstRankingEngineTests/`best relative frame still needs absolute sharpness for high confidence`()' \
	'-only-testing:RawCullSAM3Tests/ApertureHintTests/`nil aperture maps to mid`()' \
	'-only-testing:RawCullSAM3Tests/ApertureHintTests/`wide boundary is inclusive at 5 point 6`()' \
	'-only-testing:RawCullSAM3Tests/ApertureHintTests/`landscape boundary is inclusive at f 8`()' \
	'-only-testing:RawCullSAM3Tests/ApertureHintTests/`landscape has widest gate window and lowest threshold`()' \
	'-only-testing:RawCullSAM3Tests/ApertureHintTests/`only landscape overrides salient weight and damps blur`()' \
	'-only-testing:RawCullSAM3Tests/ApertureHintTests/`blur gate span is positive for every hint`()' \
	'-only-testing:RawCullSAM3Tests/ISOScalingTests/`below 800 is flat at 1 point 0`()' \
	'-only-testing:RawCullSAM3Tests/ISOScalingTests/`mid range ramps to 1 point 6 at 3200`()' \
	'-only-testing:RawCullSAM3Tests/ISOScalingTests/`high range caps at 2 point 2`()' \
	'-only-testing:RawCullSAM3Tests/ISOScalingTests/`monotonically non decreasing across range`()' \
	'-only-testing:RawCullSAM3Tests/ISOScalingTests/`high ISO is less aggressive than old sqrt formula`()' \
	'-only-testing:RawCullSAM3Tests/ComparisonCandidateInspectorTests/`exif footer omits missing fields and preserves display order`()' \
	'-only-testing:RawCullSAM3Tests/ComparisonCandidateInspectorTests/`candidate context resolves selected rank saliency scores and focus points`()' \
	'-only-testing:RawCullSAM3Tests/ComparisonCandidateInspectorTests/`finalist focus uses recommended finalists without mutating source ids`()' \
	'-only-testing:RawCullSAM3Tests/ComparisonCandidateInspectorTests/`finalist focus falls back to ranked candidates when recommendation ids are missing`()' \
	'-only-testing:RawCullSAM3Tests/ComparisonCandidateInspectorTests/`finalist focus falls back to file ids when candidates are missing`()'
PERFORMANCE_ONLY_TESTING = \
	'-only-testing:RawCullSAM3Tests/DataRaceDetectionTests/`Extreme concurrent load reveals no data races`()'

SAM3_BUNDLE_DIR = RawCullSAM3/Resources/Models/SAM3
SAM3_INSTALL_DIR ?= $(HOME)/Library/Containers/no.blogspot.RawCullSAM3/Data/Library/Application Support/RawCullSAM3/Models/SAM3
SAM3_COMPILE_ARCH ?= h16c
SAM3_ASSET ?= sam3_float16.aimodel
SAM3_GPU_ASSET ?= sam3_float16_source.gpu.aimodelc
CLIP_BUNDLE_DIR = RawCullSAM3/Resources/Models/CLIP
CLIP_INSTALL_DIR ?= $(HOME)/Library/Containers/no.blogspot.RawCullSAM3/Data/Library/Application Support/RawCullSAM3/Models/CLIP
CLIP_ASSET ?= clip-vit-base-patch32_float16_static.aimodel

.DEFAULT_GOAL := release

release: build-release verify-release-model verify-clip-model

debug: build-debug verify-debug-model

build-release:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'platform=macOS' \
		-configuration Release \
		build
	@$(MAKE) print-release-app

build-debug:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'platform=macOS' \
		-configuration Debug \
		build
	@$(MAKE) print-debug-app

verify-release-model:
	@$(MAKE) verify-model

verify-debug-model:
	@$(MAKE) verify-model

verify-model:
	@test -d "$(SAM3_INSTALL_DIR)" || (echo "Missing installed SAM3 bundle: $(SAM3_INSTALL_DIR)" && exit 1)
	@test -f "$(SAM3_INSTALL_DIR)/metadata.json" || (echo "Missing installed SAM3 metadata.json" && exit 1)
	@test -f "$(SAM3_INSTALL_DIR)/tokenizer/tokenizer.json" || (echo "Missing installed SAM3 tokenizer/tokenizer.json" && exit 1)
	@SAM3_INSTALLED_ASSET="$$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("assets", {}).get("main", ""))' "$(SAM3_INSTALL_DIR)/metadata.json")"; \
	test -n "$$SAM3_INSTALLED_ASSET" || (echo "Installed SAM3 metadata.json does not define assets.main" && exit 1); \
	test -e "$(SAM3_INSTALL_DIR)/$$SAM3_INSTALLED_ASSET" || (echo "Missing installed SAM3 asset: $$SAM3_INSTALLED_ASSET" && exit 1); \
	echo "SAM3 model installed at $(SAM3_INSTALL_DIR) using $$SAM3_INSTALLED_ASSET"

verify-clip-model:
	@test -d "$(CLIP_INSTALL_DIR)" || (echo "Missing installed CLIP bundle: $(CLIP_INSTALL_DIR)" && exit 1)
	@test -f "$(CLIP_INSTALL_DIR)/metadata.json" || (echo "Missing installed CLIP metadata.json" && exit 1)
	@test -f "$(CLIP_INSTALL_DIR)/tokenizer/tokenizer.json" || (echo "Missing installed CLIP tokenizer/tokenizer.json" && exit 1)
	@CLIP_INSTALLED_ASSET="$$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("assets", {}).get("main", ""))' "$(CLIP_INSTALL_DIR)/metadata.json")"; \
	test -n "$$CLIP_INSTALLED_ASSET" || (echo "Installed CLIP metadata.json does not define assets.main" && exit 1); \
	test -e "$(CLIP_INSTALL_DIR)/$$CLIP_INSTALLED_ASSET" || (echo "Missing installed CLIP asset: $$CLIP_INSTALLED_ASSET" && exit 1); \
	echo "CLIP model installed at $(CLIP_INSTALL_DIR) using $$CLIP_INSTALLED_ASSET"

install-sam3-model:
	@test -d "$(SAM3_BUNDLE_DIR)" || (echo "Missing local SAM3 bundle: $(SAM3_BUNDLE_DIR)" && exit 1)
	@test -f "$(SAM3_BUNDLE_DIR)/metadata.json" || (echo "Missing local SAM3 metadata.json" && exit 1)
	@mkdir -p "$$(dirname "$(SAM3_INSTALL_DIR)")"
	@rsync -a --exclude .DS_Store "$(SAM3_BUNDLE_DIR)/" "$(SAM3_INSTALL_DIR)/"
	@$(MAKE) verify-model

install-clip-model:
	@test -d "$(CLIP_BUNDLE_DIR)" || (echo "Missing local CLIP bundle: $(CLIP_BUNDLE_DIR)" && exit 1)
	@test -f "$(CLIP_BUNDLE_DIR)/metadata.json" || (echo "Missing local CLIP metadata.json" && exit 1)
	@mkdir -p "$$(dirname "$(CLIP_INSTALL_DIR)")"
	@rsync -a --exclude .DS_Store "$(CLIP_BUNDLE_DIR)/" "$(CLIP_INSTALL_DIR)/"
	@$(MAKE) verify-clip-model

sam3-export:
	uv run tools/export_sam3.py --dtype float16 --overwrite

clip-export:
	uv run tools/export_clip.py --dtype float16 --overwrite

sam3-compile:
	xcrun coreai-build compile $(SAM3_BUNDLE_DIR)/sam3_float16_source.aimodel --platform macOS --architecture $(SAM3_COMPILE_ARCH) --output $(SAM3_BUNDLE_DIR)

clip-compile:
	xcrun coreai-build compile $(CLIP_BUNDLE_DIR)/clip-vit-base-patch32_float16_static_source.aimodel --platform macOS --architecture $(SAM3_COMPILE_ARCH) --output $(CLIP_BUNDLE_DIR)

sam3-compile-gpu:
	xcrun coreai-build compile $(SAM3_BUNDLE_DIR)/sam3_float16_source.aimodel --platform macOS --preferred-compute gpu --output $(SAM3_BUNDLE_DIR)/$(SAM3_GPU_ASSET)

sam3-compile-all:
	xcrun coreai-build compile $(SAM3_BUNDLE_DIR)/sam3_float16_source.aimodel --platform macOS --output $(SAM3_BUNDLE_DIR)

sam3-use-asset:
	python3 tools/select_sam3_asset.py $(SAM3_ASSET)

clean:
	rm -rf build

test-smoke:
	xcodebuild test $(XCODE_TEST_FLAGS) -testPlan Smoke $(SMOKE_ONLY_TESTING)

test-full:
	xcodebuild test $(XCODE_TEST_FLAGS) -testPlan RawCull -enableThreadSanitizer YES

test-performance:
	xcodebuild test $(XCODE_TEST_FLAGS) -testPlan Performance $(PERFORMANCE_ONLY_TESTING)

print-release-app:
	@find "$(DERIVED_DATA_ROOT)" -path "*/Build/Products/Release/$(APP).app" -not -path "*/Index.noindex/*" -type d -print -quit

print-debug-app:
	@find "$(DERIVED_DATA_ROOT)" -path "*/Build/Products/Debug/$(APP).app" -not -path "*/Index.noindex/*" -type d -print -quit

.PHONY: release debug build-release build-debug verify-release-model verify-debug-model verify-model verify-clip-model install-sam3-model install-clip-model \
	sam3-export clip-export sam3-compile clip-compile sam3-compile-gpu sam3-compile-all sam3-use-asset clean test-smoke test-full test-performance \
	print-release-app print-debug-app
