#!/bin/bash
# build-guard-test.sh: which lobby a build would get, decided by
# release-build.sh and the Makefile, without building anything.
# Drives the REAL release-build.sh with --print-config, which stops right after
# the option parser, the Developer ID guard and the test-server checks, and the
# REAL Makefile with `make -n`. Covers: the default test server, BAR's lobby as
# an opt-in that a Developer ID build refuses, a BAR host refused as a "test
# server", and exported variables that must not choose the lobby.
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PKG/.." && pwd)"
RB="$PKG/release-build.sh"
# a clean slate: none of the variables under test may leak in from the caller
unset BAR_ONLINE TELLURION_LOBBY ONLINE LOBBY BAR_CONTENT_TAGS BAR_MESSAGES_CONFIG TELLURION_UPDATE_FEED MAKEFLAGS MAKEOVERRIDES
ID="Developer ID Application: Test (TEAMID0000)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf "  ok   %s\n" "$1"; }
bad() { fail=$((fail+1)); printf "  FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "       got: %s\n" "$2"; }
# says <expected last line> <release-build args...>: exit 0 and that report
says() { local want="$1"; shift; local out; out=$("$RB" --print-config "$@" 2>&1); local rc=$?
         { [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "$want" ]; } \
           && ok "$* -> $want" || bad "$* -> $want" "rc=$rc $out"; }
# refuses <text the message must hold> <release-build args...>: exit 2
refuses() { local want="$1"; shift; local out; out=$("$RB" --print-config "$@" 2>&1); local rc=$?
            { [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -qF -- "$want"; } \
              && ok "refused: $*" || bad "should refuse: $*" "rc=$rc $out"; }

echo "== ad-hoc build: the three modes =="
says "online: test server tlr.qant.au:8200"
says "online: test server tlr.qant.au:8200" --online-tellurion
says "online: test server 10.0.0.5:8200" --lobby-server 10.0.0.5:8200
says "online: disabled" --disable-online
says "online: BAR's lobby" --enable-online

echo "== a test server is never a BAR server, and must be host:port =="
for h in server4.beyondallreason.info:8200 Server4.BeyondAllReason.INFO:8200 server4.beyondallreason.info.:8200 \
         beyondallreason.info:8200 repos-cdn.beyondallreason.dev:443; do
  refuses "is a BAR server" --lobby-server "$h"
done
for h in tlr.qant.au tlr.qant.au: :8200 tlr.qant.au:0 tlr.qant.au:08200 tlr.qant.au:99999 tlr.qant.au:82a0 \
         "tlr.qant.au:8200@evil.test" "bad host:8200" 'a"b:8200' "[::1]:8200"; do
  refuses "FATAL: --lobby-server" --lobby-server "$h"
done

echo "== exported variables do not choose the server =="
out=$(TELLURION_LOBBY=evil.test:1 "$RB" --print-config 2>&1 | tail -1)
[ "$out" = "online: test server tlr.qant.au:8200" ] && ok "an exported TELLURION_LOBBY is ignored" || bad "TELLURION_LOBBY honoured" "$out"
out=$(BAR_ONLINE=1 "$RB" --print-config --identity "$ID" 2>&1); rc=$?
{ [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q "online play goes to BAR's lobby"; } \
  && ok "an exported BAR_ONLINE=1 is refused by a Developer ID build" || bad "BAR_ONLINE=1 with an identity" "rc=$rc $out"

echo "== Developer ID build: only the standard test server =="
says "online: test server tlr.qant.au:8200" --identity "$ID"
says "online: test server tlr.qant.au:8200" --identity "$ID" --lobby-server tlr.qant.au:8200
refuses "online play goes to BAR's lobby" --identity "$ID" --enable-online
refuses "online play goes to BAR's lobby" --enable-online --identity "$ID"
for h in 10.0.0.5:8200 tlr.qant.au.evil.test:8200 TLR.QANT.AU:8200 tlr.qant.au.:8200 tlr.qant.au:8201; do
  refuses "lobby server is not the default" --identity "$ID" --lobby-server "$h"
done
says "online: test server 10.0.0.5:8200" --identity "$ID" --lobby-server 10.0.0.5:8200 --allow-release-overrides
says "online: BAR's lobby" --identity "$ID" --enable-online --allow-release-overrides

echo "== Makefile: ONLINE and LOBBY count only on the make command line =="
# mk <expected args> [make args...]: the release-build.sh line `make -n app` would run
mk() { local want="$1"; shift; local line; line=$(make -C "$ROOT" -n app "$@" 2>&1 | grep 'release-build.sh' | tail -1)
       case "$line" in *"$want"*) return 0;; *) GOT="$line"; return 1;; esac; }
mk "--online-tellurion" && ! mk "--lobby-server" && ok "plain make app -> the test server setting" || bad "plain make app" "${GOT:-}"
mk "--enable-online" ONLINE=1 && ok "make app ONLINE=1 -> BAR's standard settings" || bad "ONLINE=1 on the command line" "${GOT:-}"
mk "--disable-online" ONLINE=0 && ok "make app ONLINE=0 -> online play off" || bad "ONLINE=0 on the command line" "${GOT:-}"
mk '--online-tellurion --lobby-server "10.0.0.5:8200"' LOBBY=10.0.0.5:8200 && ok "make app LOBBY=host:port -> that test server" || bad "LOBBY on the command line" "${GOT:-}"
( export ONLINE=1; mk "--online-tellurion" && ! mk "--enable-online" ) && ok "an exported ONLINE=1 is ignored" || bad "exported ONLINE=1 honoured"
( export ONLINE=0; mk "--online-tellurion" && ! mk "--disable-online" ) && ok "an exported ONLINE=0 is ignored" || bad "exported ONLINE=0 honoured"
( export LOBBY=10.0.0.5:8200; mk "--online-tellurion" && ! mk "--lobby-server" ) && ok "an exported LOBBY is ignored" || bad "exported LOBBY honoured"
( export ONLINE=1; mk "--online-tellurion" -e && ! mk "--enable-online" -e ) && ok "make -e does not let the environment in either" || bad "make -e ONLINE=1 honoured"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
