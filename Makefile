# ===========================================================================
# IPA-Patch tweak Makefile.
#
# Targets:
#   make            — JB rootless .deb (MSHookFunction via libsubstrate)
#   make package    — same, packaged
#   make jailed     — Dobby-static .dylib for Sideloadly injection (iOS 15-17)
#   make chinlan   — Dobby-static .dylib for the statically-patched IPA path
#                     (iOS 18 sideload; the only mode that survives CSM).
#   make ipa        — patched IPA assembled from $(DECRYPTED_IPA)
#
# Layout: every project-specific value lives in the PROJECT VARIABLES
# block below. Adapting this Makefile to a sibling tweak should be that
# one block + the recipe + the source dir; the build rules below stay
# verbatim.
# ===========================================================================

# ---------------------------------------------------------------------------
# PROJECT VARIABLES — only block that needs editing per tweak.
# ---------------------------------------------------------------------------
TWEAK_NAME               := PiyoShot
TWEAK_SOURCES_DIR        := Sources/$(TWEAK_NAME)

# Process killed at install-time and bundle id used to relaunch the host app.
TARGET_PROCESS           := PiyoShogi
TARGET_BUNDLE_ID         := net.studioki.PiyoShogi

# Decrypted IPA the binpatch pipeline consumes. App Store IPAs ship
# FairPlay-encrypted; you need a frida-ios-dump-style decrypted copy.
# The patcher never redistributes it; the operator drops one under
# assets/. Override on the command line:
#   make ipa DECRYPTED_IPA=/path/to/decrypted.ipa
DECRYPTED_IPA            ?= $(CURDIR)/assets/PiyoShogi-5.7.5.ipa
# Python recipe module driving the static patcher (must be importable from
# the project root with `recipes/` on PYTHONPATH).
IPA_RECIPE               := recipes.piyoshot
# Mach-O basename inside the IPA that recipes/ targets. For PiyoShot the
# hook sites live directly in the main app executable, not a framework —
# so this is the CFBundleExecutable, not a Frameworks/*.framework binary.
IPA_FRAMEWORK            := PiyoShogi

# Preprocessor macro that carries the short HEAD commit into the dylib
# (referenced from C as a string literal). Rename freely; just keep the
# matching `#ifndef … #define …` in the tweak's Internal.h aligned.
BUILD_COMMIT_DEFINE      := PIYOSHOT_COMMIT

# ---------------------------------------------------------------------------
# Theos boilerplate.
# ---------------------------------------------------------------------------
TARGET                   := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := $(TARGET_PROCESS)
ARCHS                    := arm64
THEOS_PACKAGE_SCHEME     := rootless
# Devcontainer default: usbmuxd (or iproxy) on the host forwards 2222 → 22 on
# the attached JB device, and the container reaches it via host.docker.internal.
# Override by exporting THEOS_DEVICE_IP / THEOS_DEVICE_PORT in your shell rc
# (or via devcontainer.json's remoteEnv) — `?=` keeps env overrides winning.
THEOS_DEVICE_IP          ?= host.docker.internal
THEOS_DEVICE_PORT        ?= 2222

include $(THEOS)/makefiles/common.mk

# Theos derives every per-tweak variable from $(TWEAK_NAME) — the
# variable's exact case must match the tweak name. Going through
# $(TWEAK_NAME)_FOO keeps that constraint in one place and stops the
# build file from sprouting a "PiyoShot_" CamelCase prefix next to
# the project's own UPPER_SNAKE_CASE macros.
$(TWEAK_NAME)_FILES      := $(shell find $(TWEAK_SOURCES_DIR) -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
# Common runtime — git submodule at Sources/Chinlan. il2cpp.h /
# hookengine.h are header-only; logging.m and chinlan.m are the only
# translation units to compile. chinlan.m exports two read-only
# helpers (image lookup + B<cave> decode) used only by the IPA_CHINLAN
# build's ChinlanDispatcher.m; on the JB / jailed paths the linker drops
# the unreferenced symbols, so including it unconditionally keeps one
# file list across all build flavors.
$(TWEAK_NAME)_FILES      += Sources/Chinlan/logging.m
$(TWEAK_NAME)_FILES      += Sources/Chinlan/logserver.m
$(TWEAK_NAME)_FILES      += Sources/Chinlan/chinlan.m

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
BUILD_COMMIT             ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

# Version is read straight from the control file's `Version:` line and
# gets a `-dbg` suffix for non-release builds. Bumping the tweak just
# needs one edit to control; commit hash is baked separately into
# BUILD_COMMIT_DEFINE so the Sheet's Info section can show both.
_CONTROL_VERSION         := $(shell grep '^Version:' control | awk '{print $$2}')
ifneq ($(FINALPACKAGE),1)
PACKAGE_VERSION          := $(_CONTROL_VERSION)-dbg
else
PACKAGE_VERSION          := $(_CONTROL_VERSION)
endif
# `override` needed because Theos's package/deb.mk re-assigns
# THEOS_PACKAGE_BASE_VERSION from the control file's raw Version:
# without the -dbg suffix. `PACKAGE_VERSION` is likewise clobbered by
# package.mk's `override PACKAGE_VERSION = $(__PACKAGE_VERSION)`, so
# we pull directly from _CONTROL_VERSION here rather than through
# PACKAGE_VERSION.
ifneq ($(FINALPACKAGE),1)
override THEOS_PACKAGE_BASE_VERSION := $(_CONTROL_VERSION)-dbg
else
override THEOS_PACKAGE_BASE_VERSION := $(_CONTROL_VERSION)
endif

# C-side macro name stays tweak-specific (matches Internal.h) but the
# right-hand side pulls from the generic PACKAGE_VERSION.
$(TWEAK_NAME)_CFLAGS     := -fobjc-arc -Wno-unused-function \
                            -D$(BUILD_COMMIT_DEFINE)=\"$(BUILD_COMMIT)\" \
                            -DPIYOSHOT_VERSION=\"$(PACKAGE_VERSION)\" \
                            -ISources/Chinlan -I$(TWEAK_SOURCES_DIR)
$(TWEAK_NAME)_FRAMEWORKS := Foundation UIKit UniformTypeIdentifiers

# ---------------------------------------------------------------------------
# Hook engine / distribution selection.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction in libsubstrate).
#   JAILED=1               : Dobby, statically linked from vendor/dobby/lib/
#                            libdobby.a so the dylib has no external
#                            hook-engine dependency. Useful on jailbroken
#                            iOS 15-17; on iOS 18 the runtime mprotect/memcpy
#                            inline rewrite is killed by Code Signing Monitor
#                            (see docs/chinlan.md), so iOS 18 sideload
#                            targets must go through CHINLAN=1 instead.
#   CHINLAN=1             : Statically-patched $(IPA_FRAMEWORK) distribution.
#                            The Mach-O is rewritten ahead of time so each
#                            hook site BL's into a __TEXT cave that calls
#                            the dylib through a __DATA hook-slot table;
#                            the dylib only ever writes to __DATA so CSM
#                            stays happy. Implies JAILED=1 (no libsubstrate
#                            dependency) and routes the file log into
#                            Documents/ so operators can read it via
#                            Files.app.
#
# Internal.h's hook-engine shim picks the matching API at compile time.
# ---------------------------------------------------------------------------
ifeq ($(CHINLAN),1)
    JAILED                   := 1
    $(TWEAK_NAME)_CFLAGS     += -DIPA_CHINLAN=1 -DIPA_LOG_TO_DOCUMENTS=1
endif

ifeq ($(JAILED),1)
    $(TWEAK_NAME)_CFLAGS     += -DIPA_JAILED=1 -Ivendor/dobby/include
    # Dobby is C++; pull in libc++ for __cxa_guard_*, __cxa_pure_virtual, etc.
    $(TWEAK_NAME)_LDFLAGS    := -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
else
    $(TWEAK_NAME)_LDFLAGS    := -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/$(TWEAK_NAME).dylib"
	# INSTALL_TARGET_PROCESSES killed the app; relaunch via whichever launcher tool is present.
	install.exec "sleep 1; (open $(TARGET_BUNDLE_ID) 2>/dev/null || uiopen $(TARGET_BUNDLE_ID):// 2>/dev/null || echo 'no launcher tool (uiopen/open); start $(TARGET_PROCESS) manually')"

# jailed distribution: rebuild with Dobby statically linked, then copy the
# resulting .dylib into packages/jailed/ for Sideloadly injection.
# Verifies the final binary has no libsubstrate/libdobby external dep.
jailed::
	$(MAKE) JAILED=1 clean
	$(MAKE) JAILED=1 all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/jailed/$(TWEAK_NAME).dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/$(TWEAK_NAME).dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/jailed/$(TWEAK_NAME).dylib 2>/dev/null \
	  || otool -L packages/jailed/$(TWEAK_NAME).dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# ---------------------------------------------------------------------------
# chinlan distribution: same link shape as `jailed::` (Dobby statically
# linked, no libsubstrate dependency) but with -DIPA_CHINLAN=1 so the
# constructor publishes hook function pointers into the patched binary's
# reserved __DATA slot table instead of trying to inline-rewrite __TEXT.
# This is the only build mode that survives iOS 18's Code Signing Monitor
# on a sideloaded IPA. Drops the artifact into packages/chinlan/.
# ---------------------------------------------------------------------------
chinlan::
	$(MAKE) CHINLAN=1 clean
	$(MAKE) CHINLAN=1 all
	$(ECHO_NOTHING)mkdir -p packages/chinlan$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/chinlan/$(TWEAK_NAME).dylib$(ECHO_END)
	@echo "chinlan dylib -> packages/chinlan/$(TWEAK_NAME).dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/chinlan/$(TWEAK_NAME).dylib 2>/dev/null \
	  || otool -L packages/chinlan/$(TWEAK_NAME).dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# ---------------------------------------------------------------------------
# Full patched-IPA pipeline.
#
# Builds the chinlan dylib (if missing) and assembles a TrollStore /
# Sideloadly / AltStore / Apple Developer Program-ready IPA from the
# decrypted IPA supplied by the operator via DECRYPTED_IPA. The patcher
# itself is the target-agnostic shared/tools/build_patched_ipa.sh driven
# by the tweak-specific recipe ($(IPA_RECIPE)).
#
# This target NEVER ships a decrypted target IPA — supply your own
# (see docs/porting.md for the dump procedure).
# ---------------------------------------------------------------------------
IPA_DYLIB                := $(CURDIR)/packages/chinlan/$(TWEAK_NAME).dylib
BUNDLED_JSONL            := $(CURDIR)/layout/Library/Application Support/$(TWEAK_NAME)/position.jsonl
IPA_OUT_DIR              := $(CURDIR)/packages/ipa

ipa:: chinlan
	@echo "==> assembling patched IPA from $(DECRYPTED_IPA)"
	@if [ ! -f "$(DECRYPTED_IPA)" ]; then \
	  echo "error: decrypted IPA missing at $(DECRYPTED_IPA)"; \
	  echo "       override with: make ipa DECRYPTED_IPA=/path/to/decrypted.ipa"; \
	  exit 1; \
	fi
	@./shared/tools/build_patched_ipa.sh \
	  --recipe    "$(IPA_RECIPE)" \
	  --framework "$(IPA_FRAMEWORK)" \
	  --dylib     "$(IPA_DYLIB)" \
	  --input     "$(DECRYPTED_IPA)"
# Drop the bundled JSONL next to the dylib inside the produced IPA so
# PiyoSheetVC's findBundledJsonlPath() finds it in sideload mode
# (chinlan builds have no /var/jb/ path). Uses the freshest .ipa in
# IPA_OUT_DIR — build_patched_ipa.sh names it after the input IPA in
# Kanade v0.1.3+, so we don't hard-code the basename here.
	@if [ ! -f "$(BUNDLED_JSONL)" ]; then \
	  echo "warning: bundled JSONL missing at $(BUNDLED_JSONL) — skipping injection"; \
	  exit 0; \
	fi; \
	OUT_IPA=$$(ls -t "$(IPA_OUT_DIR)"/*.ipa 2>/dev/null | head -n1); \
	if [ -z "$$OUT_IPA" ]; then \
	  echo "warning: no IPA found in $(IPA_OUT_DIR) — injection skipped"; \
	  exit 0; \
	fi; \
	APP_DIR=$$(unzip -Z1 "$$OUT_IPA" 'Payload/*.app/' 2>/dev/null | head -n1); \
	if [ -z "$$APP_DIR" ]; then \
	  echo "warning: no .app inside $$OUT_IPA — injection skipped"; \
	  exit 0; \
	fi; \
	STAGE=$$(mktemp -d); \
	trap "rm -rf $$STAGE" EXIT; \
	mkdir -p "$$STAGE/$${APP_DIR}Frameworks"; \
	cp "$(BUNDLED_JSONL)" "$$STAGE/$${APP_DIR}Frameworks/position.jsonl"; \
	(cd "$$STAGE" && zip -qrX "$$OUT_IPA" Payload); \
	echo "==> injected position.jsonl -> $${APP_DIR}Frameworks/ inside $$(basename "$$OUT_IPA")"

# ---------------------------------------------------------------------------
# Release artifacts are assembled by the deployment workflow, not by
# this Makefile. The CD pipeline fans out `make package / jailed /
# chinlan FINALPACKAGE=1` and then stages the three Theos-shaped
# artifacts straight into `dist/`:
#
#   work.tkgstrator.piyoshot_<ver>_iphoneos-arm64.deb
#   work.tkgstrator.piyoshot_<ver>_iphoneos-arm64-jailed.dylib
#   work.tkgstrator.piyoshot_<ver>_iphoneos-arm64-binpatch.dylib
#
# The dylib stems are derived from the .deb filename, so the bundle-id /
# version / arch prefix stays in sync with whatever Theos chose for the
# package. Operators who want the same layout locally can mirror the
# workflow step out of .github/workflows/deployment.yaml.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Developer hooks. Point core.hooksPath at scripts/ so scripts/pre-commit
# fires before every commit. The hook runs the recipe<->dump cross-check
# (verify_sites) when a commit touches recipes/ or shared/tools/, and is
# a no-op otherwise — including on workstations without the local dump
# index. See scripts/pre-commit for the full contract.
# ---------------------------------------------------------------------------
.PHONY: hooks
hooks::
	git config core.hooksPath scripts
	@echo "git hooks now resolve under scripts/ (pre-commit installed)"
