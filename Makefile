# sudo ditto "$(make print-release-app)" "/Applications/RawCullSAM3.app"
# find "/Applications/RawCullSAM3.app/Contents/Resources" -name "sam3_float16_source.h16c.aimodelc" -type d -print
# find "/Applications/RawCullSAM3.app/Contents/Resources" \( -name "metadata.json" -o -name "tokenizer.json" \) -print

APP ?= RawCullSAM3
SCHEME ?= RawCullSAM3
PROJECT ?= RawCullSAM3.xcodeproj

DERIVED_DATA_ROOT ?= $(HOME)/Library/Developer/Xcode/DerivedData

SAM3_BUNDLE_DIR = RawCullSAM3/Resources/Models/SAM3
SAM3_COMPILE_ARCH ?= h16c
SAM3_ASSET ?= sam3_float16_source.h16c.aimodelc

.DEFAULT_GOAL := release

release: build-release verify-release-model

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
	@APP_BUNDLE="$$(find "$(DERIVED_DATA_ROOT)" -path "*/Build/Products/Release/$(APP).app" -type d -print -quit)"; \
	$(MAKE) verify-model APP_BUNDLE="$$APP_BUNDLE"

verify-debug-model:
	@APP_BUNDLE="$$(find "$(DERIVED_DATA_ROOT)" -path "*/Build/Products/Debug/$(APP).app" -type d -print -quit)"; \
	$(MAKE) verify-model APP_BUNDLE="$$APP_BUNDLE"

verify-model:
	@test -d "$(SAM3_BUNDLE_DIR)" || (echo "Missing local SAM3 bundle: $(SAM3_BUNDLE_DIR)" && exit 1)
	@test -f "$(SAM3_BUNDLE_DIR)/metadata.json" || (echo "Missing SAM3 metadata.json" && exit 1)
	@test -d "$(SAM3_BUNDLE_DIR)/$(SAM3_ASSET)" || (echo "Missing local SAM3 asset: $(SAM3_ASSET)" && exit 1)
	@test -d "$(APP_BUNDLE)" || (echo "Missing app bundle: $(APP_BUNDLE)" && exit 1)
	@if [ -d "$(APP_BUNDLE)/Contents/Resources/Models/SAM3/$(SAM3_ASSET)" ]; then \
		echo "SAM3 model copied as Models/SAM3/$(SAM3_ASSET)"; \
	elif [ -d "$(APP_BUNDLE)/Contents/Resources/SAM3/$(SAM3_ASSET)" ]; then \
		echo "SAM3 model copied as SAM3/$(SAM3_ASSET)"; \
	elif [ -d "$(APP_BUNDLE)/Contents/Resources/$(SAM3_ASSET)" ]; then \
		test -f "$(APP_BUNDLE)/Contents/Resources/metadata.json" || (echo "Missing flattened SAM3 metadata.json in app bundle" && exit 1); \
		test -f "$(APP_BUNDLE)/Contents/Resources/tokenizer.json" -o -f "$(APP_BUNDLE)/Contents/Resources/tokenizer/tokenizer.json" || (echo "Missing SAM3 tokenizer in app bundle" && exit 1); \
		echo "SAM3 model copied as flattened resource $(SAM3_ASSET)"; \
	else \
		echo "SAM3 model asset was not copied into $(APP_BUNDLE)/Contents/Resources"; \
		exit 1; \
	fi

sam3-export:
	uv run tools/export_sam3.py --dtype float16 --overwrite

sam3-compile:
	xcrun coreai-build compile $(SAM3_BUNDLE_DIR)/sam3_float16_source.aimodel --platform macOS --architecture $(SAM3_COMPILE_ARCH) --output $(SAM3_BUNDLE_DIR)

sam3-compile-all:
	xcrun coreai-build compile $(SAM3_BUNDLE_DIR)/sam3_float16_source.aimodel --platform macOS --output $(SAM3_BUNDLE_DIR)

sam3-use-asset:
	python3 tools/select_sam3_asset.py $(SAM3_ASSET)

clean:
	rm -rf build

print-release-app:
	@find "$(DERIVED_DATA_ROOT)" -path "*/Build/Products/Release/$(APP).app" -type d -print -quit

print-debug-app:
	@find "$(DERIVED_DATA_ROOT)" -path "*/Build/Products/Debug/$(APP).app" -type d -print -quit

.PHONY: release debug build-release build-debug verify-release-model verify-debug-model verify-model \
	sam3-export sam3-compile sam3-compile-all sam3-use-asset clean print-release-app print-debug-app
