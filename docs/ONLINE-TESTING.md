# Online testing on the Tellurion test server

This file lives on the `play-server` branch only. `main` allows BAR's official
servers and nothing else; every test-server change goes on this branch.

The server is the private Teiserver fork plus SPADS (`qant-au/tellurion-server`)
on dione. Lobby TCP 8200, games UDP 53200-53209, engine 2026.09.03 (the same as
BAR production). Registration is closed: accounts come from
`ssh dione '~/tellurion-server/tellurion/admin.sh add <name> <email>'`, which
prints the password.

Until the router forwards those ports, `tlr.qant.au` only works from outside
the LAN. On the LAN use dione's address, `10.49.39.111`.

## Mac (Tellurion)

    git switch play-server
    RELEASE_OUT="$PWD/release-artifacts/play-server" make app LOBBY=10.49.39.111:8200

`RELEASE_OUT` keeps the test app apart from the everyday build in
`release-artifacts/`. Leave out `LOBBY=` for `tlr.qant.au:8200`.

## Windows and Linux (stock BAR)

No build is needed. The stock BAR client can point at another server:

1. Quit BAR. In BAR's data folder (the one that holds `infolog.txt`), create
   an empty file named `devmode.txt`.
2. Start BAR. Settings now has a **Developer** tab. Set **Server Address** to
   `10.49.39.111` (or `tlr.qant.au`); the port stays 8200.
3. Restart the lobby and log in with a test-server account.

To go back to BAR's servers, set Server Address to
`server4.beyondallreason.info` and delete `devmode.txt`.

BAR's launcher must be on its normal (production) config, which uses engine
2026.09.03, the same as the server. The "test engine" config uses a newer
engine and will not join.

## A game with AIs

SPADS hosts the battle (`TLRcluster[000]`). Join it, add AIs from the battle
room, then start. An AI runs inside the client of the player who added it, so
one player plus AIs is enough for a first test; a second client (Windows or
Linux) is what tests cross-platform sync.
