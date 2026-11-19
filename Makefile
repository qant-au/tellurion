# Tellurion: macOS packaging entry points.
#
# Thin wrappers over packaging/release-build.sh (the single source of truth for
# how the distributable is built). Everything real lives in that script; these
# targets exist so the build is discoverable and one-command.
#
#   make app            # build + package (headless-safe): ad-hoc
#                       # Tellurion.app + .zip + .dmg. Fast; no GPU/content/long
#                       # tests. Runs on THIS Mac; won't pass Gatekeeper elsewhere.
#   make certify        # certify tier (needs an Apple Silicon GPU + content):
#                       # build + package + streflop sync test + replay
#                       # certification + visual regression + GPU driver smoke.
#                       # Needs a fleet demo for this engine: refdemos/<engine>/
#                       # or RELEASE_SMOKE_DEMO=<file.sdfz>.
#   make release        # Developer ID signed + notarized + CERTIFIED distributable
#                       #   IDENTITY="Developer ID Application: NAME (TEAMID)" \
#                       #   NOTARY_PROFILE=<keychain-profile> make release
#   make engine-dist    # the Recoil engine port alone (no BAR helper/branding):
#                       #   signed engine bundle -> Recoil-macos-<ver>-port<p>.zip
#   make engine         # just the engine binary (no bundle) — build + sync gates
#   make clean-artifacts# remove staged bundles/zips/dmgs
#
# Tiers mirror upstream Recoil CI: the build workflow only builds + packages;
# gameplay/replay validation is separate and opt-in. Build machines use `make
# app`; certification runs on a real Apple Silicon Mac. See
# docs/BUILDING.md. Full flag surface: packaging/release-build.sh.

IDENTITY ?=
NOTARY_PROFILE ?=
VERSION  ?=
ONLINE   ?=
LOBBY    ?=

VERSION_ARG := $(if $(VERSION),--version "$(VERSION)",)
# Always explicit, so an exported BAR_ONLINE cannot decide it. The build carries
# the test server setting (tlr-067, tlr.qant.au:8200) unless ONLINE=0 (online
# off) or ONLINE=1 (no setting: BAR's standard settings and BAR's own lobby) is
# given on this command line. LOBBY=host:port names another test server, e.g. a
# LAN address while testing. ONLINE and LOBBY count only when typed on the make
# command line: a value left in the environment is ignored.
ONLINE_CLI  := $(if $(findstring command line,$(origin ONLINE)),$(ONLINE),)
LOBBY_CLI   := $(if $(findstring command line,$(origin LOBBY)),$(LOBBY),)
ONLINE_ARG  := $(if $(filter 1,$(ONLINE_CLI)),--enable-online,$(if $(filter 0,$(ONLINE_CLI)),--disable-online,--online-tellurion $(if $(LOBBY_CLI),--lobby-server "$(LOBBY_CLI)",)))

.DEFAULT_GOAL := help
.PHONY: help app engine-dist certify release engine test clean-artifacts

help:
	@echo "macOS packaging (details: docs/BUILDING.md):"
	@echo "  make app       build + package the BAR helper app -> release-artifacts/Tellurion.app (+ .zip/.dmg)"
	@echo "  make engine-dist  package the Recoil engine alone (no BAR helper/branding) -> Recoil-macos-*.zip"
	@echo "                 fast, headless-safe, ad-hoc signed (this Mac only)"
	@echo "  make certify   app + sync test, replay check, visual regression, GPU driver smoke (needs a GPU and a demo)"
	@echo "  make release   Developer ID signed + notarized + certified distributable"
	@echo "                 IDENTITY=\"Developer ID Application: NAME (TEAMID)\" NOTARY_PROFILE=<profile> make release"
	@echo "  make engine    just the engine binary (no bundle)"
	@echo "  make clean-artifacts   remove staged bundles/zips/dmgs"
	@echo "  online play goes to the test server (tlr.qant.au:8200) by default"
	@echo "  make ... LOBBY=host:port   another test server (a Developer ID build refuses it)"
	@echo "  make ... ONLINE=0          online play off"
	@echo "  make ... ONLINE=1          no test server: BAR's standard settings (a Developer ID build refuses it)"
	@echo "  ONLINE and LOBBY count only on the make command line, not from the environment"

app:
	packaging/release-build.sh $(VERSION_ARG) $(ONLINE_ARG)

engine-dist:
	packaging/release-build.sh --profile engine $(VERSION_ARG)

certify:
	packaging/release-build.sh --certify --with-synctest --with-visreg --with-dsym $(VERSION_ARG) $(ONLINE_ARG)

release:
	@test -n "$(IDENTITY)" || { echo "release: set IDENTITY=\"Developer ID Application: ...\" (and NOTARY_PROFILE for notarization)"; exit 2; }
	packaging/release-build.sh \
	  --certify --with-synctest --with-visreg \
	  --identity "$(IDENTITY)" \
	  $(if $(NOTARY_PROFILE),--notary-profile "$(NOTARY_PROFILE)",) \
	  $(VERSION_ARG) $(ONLINE_ARG)

engine:
	scripts/build-engine.sh

test:
	packaging/test/message-check-test.sh
	packaging/test/engine-nudge-test.sh
	packaging/test/launcher-test.sh
	packaging/test/build-guard-test.sh
	packaging/test/sl-bridge-test.sh
	packaging/test/updater-test.sh
	packaging/test/dialog-center-test.sh   # shows real windows; skips without a screen

clean-artifacts:
	rm -rf "release-artifacts/Tellurion.app" release-artifacts/*.zip release-artifacts/*.dmg release-artifacts/appcast.json
