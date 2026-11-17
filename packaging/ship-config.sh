# ship-config.sh — the shipped engine-build / driver pair, sourced by
# packaging/release-build.sh (expects $BAR to be set).
#
# Referenced by release-build.sh and build-engine.sh but absent from the public
# tree; this restores it with the defaults the scripts already document:
# build-engine.sh builds into $BAR/build-engine, and build-mesa-kk.sh notes that
# the release pipeline uses deps/mesa-native-release (never the dev driver).
# Both stay overridable through ENGINE_BUILD / MESA_PREFIX as before.
SHIP_ENGINE_BUILD="${SHIP_ENGINE_BUILD:-$BAR/build-engine}"
SHIP_MESA_PREFIX="${SHIP_MESA_PREFIX:-$BAR/deps/mesa-native-release}"
# BYAR-Chobby commit whose dist_cfg/config.json (the official launcher's config)
# release-build.sh extracts chobby_config.json + default springsettings from,
# when no local checkout sits at $BAR/chobby. f4b32fad (2026-11-16, "update
# engine versions") lists recoil_2026.09.03 as production (manual-linux/-win)
# and 2026.11.02 as Engine Test; against the previous pin a0aeca3f (2026-09-22)
# only the engine version strings in dist_cfg/config.json differ.
SHIP_CHOBBY_COMMIT="${SHIP_CHOBBY_COMMIT:-f4b32fade6813c2dc52a2864e39f6f4a1fbbafbf}"
