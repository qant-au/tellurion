# Performance

This page covers how the macOS build gets its frame rate, which switches
control it, how to measure it, and what is still worth trying.

The graphics stack is Recoil (OpenGL 4.6 compatibility profile) on Mesa Zink,
on KosmicKrisp, on Metal. Most of the work here is one story told several
times. The engine does something that costs nothing on a native OpenGL driver
and costs a lot on a translation stack. The fixes change how the stack is fed.
They do not change what is drawn.

Nothing here touches the simulation. Rendering and presentation are unsynced.
Determinism is covered in [DETERMINISM.md](DETERMINISM.md) and
[SYNC_VALIDATION.md](SYNC_VALIDATION.md). Version pins for the engine and the
driver are in [VERSIONS.md](VERSIONS.md).

## The Aim

The aim is the best frame rate and the smoothest play we can give BAR players
on Apple hardware.

It is not a like-for-like match with the official Windows and Linux builds,
because the hardware, the driver, the display and the settings all differ and
that is too many variables to track. Where the builds behave differently, the
record is [PARITY.md](PARITY.md). Compare a frame rate on this page with other
runs of this build, not with another platform.

## Summary

| Change | Code | Switch |
|---|---|---|
| Primitive restart only where it has meaning | `rts/Lua/LuaVAOImpl.cpp` | `SPRING_LUAVAO_FORCE_RESTART=1` (environment) restores the old behaviour |
| Present through a GPU readback ring | `rts/System/Platform/Mac/MacPresentBackend.mm` | `SPRING_MAC_LEGACY_PRESENT=1` (environment) forces the slow CPU path |
| Present off the render thread | `rts/System/Platform/Mac/MetalPresent.mm` | none |
| Deeper upload ring, blocking fence waits | `rts/Rendering/ModelsDataUploader.cpp`, `rts/Rendering/GL/StreamBuffer.cpp` | `SPRING_MAC_UPLOAD_BUFFERING`, `SPRING_MAC_STREAM_BUFFERING` (environment) |
| Direct present from unified memory | `rts/System/Platform/Mac/MacPresentBackend.mm`, `MetalPresent.mm` | `MacPresentDirect` (config) |
| Worker threads kept off the efficiency cores | `rts/System/Threading/ThreadPool.cpp` | `MacWorkerQos` (config) |
| Render density capped to the panel and the GPU | `rts/System/Platform/Mac/MacPresentBackend.mm` | `SPRING_MAC_FULL_BACKING=1`, `SPRING_MAC_NO_RETINA=1` (environment) |
| Render scale and upscaler | `rts/System/Platform/Mac/MacPresentBackend.mm`, `MetalPresent.mm` | `MacRenderScale`, `MacUpscaler` (config) |
| Buffered `gl.BeginEnd` drawing from Lua | `rts/Lua/LuaOpenGL.cpp` | `LuaImmediateModeBuffering` (config) |
| Pacing to the display | `rts/System/Platform/Mac/MetalPresent.mm` | `VSync` (config) |

"Config" means a key in `springsettings.cfg`. "Environment" means an
environment variable read once at startup. The environment variables are
support and debug switches. They are not settings for players.

## Primitive Restart Only Where It Has Meaning

`LuaVAOImpl` used to enable `GL_PRIMITIVE_RESTART` around every indexed draw,
triangle lists included.

A native driver ignores restart on list topologies, so that was free. Here it
is not. The engine's restart index for 32-bit index buffers is not the
all-ones value, and all-ones is the only value Metal has, so KosmicKrisp has
to unroll the index buffer in a compute pass before every such draw.

Restart is now enabled only for strip, loop and fan topologies. Engine and
game meshes never put a restart index in a list.
`SPRING_LUAVAO_FORCE_RESTART=1` brings back the unconditional enable.

This change does nothing on a native desktop driver, so it is a candidate for
upstream. See [UPSTREAM.md](UPSTREAM.md).

## Present Through a GPU Readback Ring

The engine renders into a surfaceless EGL pbuffer, and a pbuffer presents
nowhere. To reach the window, each frame is read back and drawn onto a
`CAMetalLayer` with Metal. A plain `glReadPixels` of the frame just rendered
blocks until the whole GPU pipeline has drained.

So the frame is read into a ring of pixel buffer objects, which keeps Mesa on
its GPU pack path. The frame presented is the one packed two frames earlier.
By then its buffer is idle and can be used without waiting.

Mesa stays on the fast path only while a pixel pack buffer is bound and the
read uses the framebuffer's own component order. The engine asks the driver
for that order once and logs it (`[MacPresent] impl color read ...`). If
either condition is missed, Mesa falls back to the blocking path and says
nothing.

If a faster path cannot be set up, the engine steps down in this order: the
direct path (below), the pack ring copied into an IOSurface, a blit ring, a
synchronous read. It logs a warning when it leaves the direct path and when it
ends up on the CPU staging path.

`SPRING_MAC_LEGACY_PRESENT=1` forces the original CPU staging path. The
two-frame depth is fixed unless the engine is a
[diagnostics build](#diagnostics-builds).

## Present Off the Render Thread

Calling `nextDrawable` on the render thread held light scenes at exactly half
the display refresh rate. Raising the layer's `maximumDrawableCount` did not
change that on its own.

Presents now run on a serial dispatch queue with a budget of two queued
presents. The render thread never waits inside `nextDrawable`. When both slots
are taken the frame is dropped, not torn. The next present shows newer content
anyway.

A dropped present is written to the engine log as `[MetalPresent] dropped
present (compositor 2 behind)`. The first one is logged in full and the total
is logged at exit.

## Deeper Upload Ring and Blocking Fence Waits

The persistently mapped upload ring for model transforms was three buffers
deep. That assumes the GPU finishes within two frames. This stack runs further
behind, so every map waited on a fence that had not signalled yet. The wait
loop also polled with a one nanosecond timeout, and every poll is a round trip
into the driver.

On macOS the ring is now six deep, and the fence wait blocks for up to 250
microseconds per call. It no longer spins.

`SPRING_MAC_UPLOAD_BUFFERING=n` sets the upload ring depth (3 to 8).
`SPRING_MAC_STREAM_BUFFERING=n` sets the stream buffer ring depth (2 to 8,
default 3). The stream buffer default was left alone because deeper rings
measured no gain there.

The same wait loop gives up after ten seconds without progress and closes the
game with a "Graphics device lost" message. Before, it would spin for ever on
a GPU that had stopped.

## Direct Present From Unified Memory

With the readback ring in place, each frame was still mapped and copied into
an IOSurface before Metal could draw it.

Apple GPUs share memory with the CPU, so the copy is not needed. The ring is
allocated with `glBufferStorage`, mapped once and kept mapped. Each mapped
pointer is wrapped as a Metal buffer without a copy, and the present shader
reads the pixels straight from it.

Before a slot is presented, the engine waits on that slot's fence. The wait is
deliberate. An earlier version skipped the present when the GPU was behind,
and the frame counter stayed high while the screen showed stale frames. If you
change this path, count presents and drops, not only frames per second.

`MacPresentDirect` (default 1) controls it. 0 uses the IOSurface path. It can
be changed while the game runs. If the direct path cannot be set up, the
engine falls back by itself and logs a warning.

## Worker Threads Kept Off the Efficiency Cores

macOS has no thread affinity. A thread at the default quality of service class
may be scheduled on an efficiency core, and in a parallel loop the slowest
worker sets the time for the whole group.

Workers of the synchronous thread pool now ask for the user-initiated class.
The asynchronous pool is background work and stays at the default. The present
queue is created at the user-interactive class, and the main thread asks for
it too.

`MacWorkerQos` (default 1) controls the workers. 0 leaves the scheduler
default. It can be changed while the game runs. The engine logs
`[ThreadPool] workerN QoS: ...` at startup, one line per worker.

The driver's own threads are not covered by this. See
[Open Work](#open-work).

## Render Density Capped to the Panel and the GPU

The default framebuffer follows the window's backing scale, with two caps.
The window size and the configured resolution are in points and are never
changed. Only the pixel density of the render target is.

1. **Never more pixels than the panel has.** A "scaled" desktop mode is backed
   by more pixels than the panel can show, and the window server scales it
   down. A 2560 x 1664 panel at its default scaled mode has a 2940 x 1912
   backing, which is 31% more pixels. Rendering those is wasted work.
2. **A pixel budget per GPU core.** The render target is kept to about 0.6
   megapixels per GPU core, so that a small GPU driving a large display is
   asked for only what it can draw. The cap is skipped when the core count
   cannot be read.

The scale never drops below 1. The result is logged as `[EGL] effective
backing scale ...`, with the reason when a cap applies.

`SPRING_MAC_FULL_BACKING=1` turns both caps off. `SPRING_MAC_NO_RETINA=1`
forces 1x rendering.

## Render Scale and Upscaler

`MacRenderScale` (0.5 to 1.0, default 1.0) is the fraction of the resolution
above that the game renders at. Below 1.0 the smaller frame is scaled up to
the window when it is presented. Every pixel not rendered is also a pixel not
read back.

It applies only while a loaded game is on screen. The lobby and the loading
screen render at full scale, because the lobby lays out for the engine's size
and would look larger below 1.0. The same goes for BAR's lobby when it is
shown over a running game. Each switch goes through the normal window-resize
path (`MacPresent::SetRenderScaleActive`, called from `SpringApp::Update`).
The value is also applied when the window is resized. Mac-only settings like
this one are set by the Tellurion launcher, not by BAR's settings menu.

`MacUpscaler` chooses how the frame is scaled up. 1 (default) uses the MetalFX
spatial upscaler and 0 a plain stretch. If MetalFX is not available the engine
uses the plain stretch. MetalFX is used only when `MacRenderScale` is below 1,
so the default setting presents exactly as before. `MacUpscaler` can be
changed while the game runs.

`MacCrispInterface` (default 0, needs a restart) keeps the interface and its
text at the window's full resolution while the world renders at
`MacRenderScale`. It does nothing when `MacRenderScale` is 1.

The engine still works at the `MacRenderScale` size, so the world, its
lighting and the screen effects are drawn exactly as with `MacRenderScale`
alone. Only the default framebuffer is full size. The world is drawn into an
engine-size buffer (`rts/System/Platform/Mac/CrispInterface.cpp`) and
stretched into the full-size one with plain smooth scaling, no MetalFX. The
interface pass then draws on top with its viewport and scissor scaled up.
Fonts rasterise at twice their size.

The trade-off is that the frame read back each frame is the full window, so
the mode saves world drawing and the readback costs what it did before. The
design follows
smallketchup82's [ZkMacOS](https://github.com/smallketchup82/ZkMacOS) "Retina
text and UI" mode, written again for this tree. A benchmark render-size pin
(`SPRING_MAC_PERF_RENDER_SIZE`) turns it off.

## Buffered Immediate Mode Drawing From Lua

Game widgets draw with `gl.BeginEnd`, which makes one OpenGL call per vertex.
That is cheap on a native driver and expensive here.

With `LuaImmediateModeBuffering` on, each `gl.BeginEnd` block is collected and
drawn with one `glDrawArrays` call. It is on by default on macOS only. Other
platforms keep the upstream path unless the setting is turned on. 0 restores
`glBegin` and `glEnd`. The picture is the same either way, see
[PARITY.md](PARITY.md).

## Pacing to the Display

SDL's swap interval never reaches this present path, because there is no SDL
swap. The `VSync` setting is honoured in the present code.

Any non-zero value makes the render loop wait briefly for a free present slot,
so the game renders no faster than frames reach the screen. 0 runs unpaced and
drops the surplus frames. Frames are never torn in either mode.

The engine logs `[EGL] VSync=N: frames paced to the display` or `not paced`.
Measured behaviour is recorded in [PARITY.md](PARITY.md).

## Anti-Aliasing Is Off

MSAA is off on the Mac, whatever `MSAALevel` is set to.

The default framebuffer is a pbuffer, and it is created without multisample
buffers. At startup the engine asks the driver whether the default
framebuffer is multisampled. The answer is no, so the engine sets its own MSAA
level to 0 and turns `GL_MULTISAMPLE` off. Framebuffers a game creates for
itself are not affected. The driver reports up to 4 samples for those.

This is known and has not been changed. A Windows or Linux build with the same
`MSAALevel` does more work per frame than this one, which is one more reason
not to compare frame rates across platforms (see [The Aim](#the-aim)).
Whether MSAA is worth its cost on a Retina panel is a separate question. It
has not been measured here.

## The Driver

The driver is upstream Mesa at a pinned commit plus the patches in
`patches/mesa/`, built by `scripts/build-mesa-kk.sh`. The pin and the reason
for each change of pin are in [VERSIONS.md](VERSIONS.md).

This port used to carry two of its changes as driver patches. Both now come
from upstream Mesa and were dropped at an earlier re-pin:

- **Shader math mode.** KosmicKrisp now compiles shaders in fast-math mode and
  marks only the operations that must keep their exact semantics. The engine
  sets nothing for this.
- **Render pass tracking for KosmicKrisp in Zink.**

The patches that remain are correctness and loading fixes. One of them logs a
line when the driver loads (`KOSMICKRISP_LOADED version=... path=...`), so
every log shows which copy of the driver was used.

One patch has a cost. With `MESA_KK_ZERO_MEMORY=1` the driver clears each new
memory allocation. Games written against other drivers sample textures they
have not rendered to yet and expect transparent black there. The engine sets
the variable at startup unless the environment already has it, so it is on by
default. `MESA_KK_ZERO_MEMORY=0` turns it off. The cost of the clear is an
item under [Open Work](#open-work).

The engine and the launcher set none of Mesa's own tuning variables. The
driver runs with Mesa's defaults for Zink, and on a Mac that means:

- **glthread is on.** The engine's OpenGL calls are queued and run on a Mesa
  thread named `gl`.
- **The threaded context is on.** The Zink driver runs on a second thread,
  `gdrv`.
- **Submission is threaded.** Zink hands finished batches to a third thread,
  `zfq`.

## Measuring

There is no automated performance gate. `scripts/build-engine.sh --with-perf`
says so and stops, and `scripts/visreg.sh --perf` is accepted and ignored.

These tools are in the tree.

### GPU Timers

`GPUTimers = 1` times the GPU with timestamp queries and feeds the results
into the profiler as `GPU::<label>` zones. Lua can add its own with
`gl.GPUStamp(label)`. The profiler overlay turns the stamps on while it is
open.

On a tile-based GPU the time is only attributed per pass if a pass boundary is
forced at each stamp. `GPUTimersSplitPasses = 1` does that. It costs extra
attachment loads and stores, so do not leave it on when measuring frame rate.

After 300 frames the engine logs `[GPUTimers] N stamps per frame, M unreadable
so far`. For a visual regression run, use
`VISREG_EXTRA_SETTINGS='GPUTimers = 1' scripts/visreg.sh`.

### Hitch Log

`SPRING_HITCH_LOG=<ms>` turns the profiler on and logs each frame slower than
that many milliseconds, with the timers that took longest (`[hitch] frame
...`).

The present path has its own timers under `Misc::SwapBuffers`: the pack, the
wait for the GPU and the Metal present. Swap time that none of the three
accounts for is not attributed yet (see [Open Work](#open-work)).

### Stall Log

A gap of more than 150 ms between drawn frames is logged as `[stall] draw gap
...`. The first one is logged in full, then a total and the longest gap at
exit. Every log line also reaches BAR's in-game console, so the rest are only
counted.

`SPRING_STALL_LOG_ALL=1` logs every stall with its time.
`SPRING_NO_STALL_LOG=1` turns the log off.

### Fixed Conditions

- `SPRING_MAC_PERF_PIN=1` turns display sync off and pins the colour space
  and the layer scale. That removes the attached monitor from the result. It
  tears, so never use it for play.
- `SPRING_MAC_PERF_RENDER_SIZE=<W>x<H>` fixes the render size whatever the
  window size.
- `SPRING_MAC_FIXED_WINDOW=1` keeps the window where the settings put it.
- `SPRING_DEMO_SPEED=n` plays a replay n times faster.

### Switching Inside One Run

`MacPresentDirect`, `MacUpscaler`, `MacWorkerQos` and `VSync` take effect
while the game runs, so two settings can be compared in one process on the
same scene.

### Diagnostics Builds

A build configured with `-DSPRING_MAC_DIAGNOSTICS=ON` has the heavier tools
compiled in:

- `SPRING_TIME_PRESENT` (per-stage present timing)
- `SPRING_MAC_PRESENT_LAG` and `SPRING_MAC_PRESENT_GPUPACK` (readback depth
  and path)
- `SPRING_FRAME_CAPTURE` and `SPRING_MAC_DUMP_FRAME` (raw frame dumps)

The option is off by default and `scripts/build-engine.sh` does not turn it
on, so a normal build, the packaged app included, has none of this.

### A Result That Looks Too Good

Check what reached the screen. With display pacing off, the engine can render
far more frames than it presents. The dropped presents are in the log.

## Historical Figures

These figures are **historical**. They were measured in mid 2026 during the
original optimisation work, on the 2025.06.24 engine line and on driver builds
that predate the current Mesa pin (the previous pin is recorded in
[VERSIONS.md](VERSIONS.md)). The machine was an M2 Ultra with a 5K output and
display sync on.

They have not been measured again on the current engine and driver. Read them
as the size of each effect at the time, not as what this tree does today.

| What | Before | After |
|---|---|---|
| 2,162-unit battle, all changes together | 6.8 fps | 54.4 fps |
| 1,082-unit battle, combat zoom, all changes together | 12.1 fps | 71.7 fps |
| Late-game 8v8, icon overview, all changes together | 4.7 fps | 45.5 fps |
| Primitive restart change alone, 2,162-unit battle | 6.8 fps | 23.1 fps |
| Readback ring, present cost at 5120 x 2160 | about 30 ms | about 1.3 ms |
| Upload ring, time waiting on fences per frame | about 10 ms | gone from the profile |
| Present off the render thread, light scene on a 120 Hz panel | held at 60 fps | reached the panel limit |

The totals also include a shader math change that was a driver patch at the
time and is now part of upstream Mesa.

## Open Work

The first seven items come from a review of the graphics path on 2026-11-17.
None of them has been measured. Each one says what to test first. They are in
the order of what they are expected to be worth.

### The Driver's Threads Have No Quality of Service Class

Every OpenGL call the engine makes passes through the three Mesa threads
listed under [The Driver](#the-driver). Mesa has no quality of service code,
so all three run at the default class and may be scheduled on an efficiency
core. This is the gap already closed for the engine's own workers. A comment
in `MetalPresent.mm` records what that was worth at the time: 5% on the
average frame rate and 30% on the minimum, in a simulation-bound scene.

A new thread does not inherit the class of the thread that created it. The
engine's log shows this. The main thread runs at user-interactive (`0x21`),
and the workers it creates report `0x15`, the default class, before they
promote themselves.

The fix would be a small Mesa patch that sets the class when one of these
threads starts on Apple platforms. It would be carried in `patches/mesa/` and
could be offered upstream.

It should matter most on a Mac with four performance cores (a MacBook Air, a
base MacBook Pro, a Mac mini). There the main thread and three workers already
hold every performance core. On a Mac with many performance cores it may not
show at all. The periodic hitches reported on an M1 (issue #4) could be this.
That is a guess until it is measured.

### glthread Has Never Been Compared With glthread Off

glthread is on by default for Zink. Mesa turns it off when a machine has
fewer than five big cores, but it only counts big cores on Linux. On macOS the
count stays at 0 and the guard is skipped, so every Mac with four performance
cores runs a setting that Mesa itself turns off on Linux.

There is a second reason to doubt it here. A call that returns a value makes
the engine wait for the `gl` thread to catch up. The present path and the
stream buffers call `glFenceSync` and `glClientWaitSync` every frame, and both
return a value. So the engine waits for the `gl` thread at least once a frame
whatever else it does.

The test is a change of environment only. Run the same replay with
`mesa_glthread=false` set and without it, on a Mac with four performance cores
and on one with many. If off is faster on the small Macs, the launcher can set
it for them.

### Swap Time That No Timer Accounts For

One measurement fits both items above and proves neither.

A four-hour AI skirmish on an M3 Ultra (2026-11-09, engine 2026.09.02, Mesa
26.3.0-rc3) logged 228 frames in game that took 20 ms or longer. In 124 of
them `Misc::SwapBuffers` was the largest timer, with a median frame of 50 ms.
Only 9 of the 124 named the fence wait. For the other 115 the time was inside
the swap and outside its three timers.

The code suggests where it went. The swap begins by clearing the OpenGL error
queue with `glGetError` and then fences the stream buffers with `glFenceSync`.
Both calls return a value, so this is the first place in a frame where the
engine has to wait for the `gl` thread. Whatever the driver's threads are
behind by would be charged here, before the pack timer starts.

Start by repeating the run on the current build with a timer around each of
those two calls and one around `SDL_PumpEvents`. That says whether the wait is
for the driver's threads or for something else.

### Present Latency of Two Frames

The readback ring presents the frame packed two frames earlier, and that depth
is fixed in a normal build. Up to two presents can also be queued behind it.
At 60 frames per second the ring alone adds about 33 ms between a frame being
drawn and reaching the compositor. That does not lower the frame rate. It is
what the player feels when dragging a selection box or moving the camera.

One option is to present the frame packed one frame earlier whenever its fence
has already signalled, and to fall back to the two-frame slot and its wait
when it has not. That keeps the backpressure described under
[Direct Present From Unified Memory](#direct-present-from-unified-memory).
The risk is uneven pacing if the two depths alternate.

A diagnostics build can test a depth of one directly with
`SPRING_MAC_PRESENT_LAG=1`. Count the fence waits and watch the frame times.

### The Cost of Clearing Driver Memory

`MESA_KK_ZERO_MEMORY=1` (see [The Driver](#the-driver)) clears every
allocation with a CPU `memset`, which also touches every page of it. That
costs time while the game loads, and it makes all of that memory resident at
once, which matters on a Mac with 8 GB. A large allocation in the middle of a
game stalls for as long as its clear takes. The present ring at 5K is six
buffers of 59 MB.

The test is load time and memory footprint with the variable at 0 and at 1,
on the Mac with the least memory. If the difference shows, the clear could be
kept for image memory only, which is the case the patch exists for.

### Whether Game Mode Turns On

macOS has a Game Mode that gives a full-screen game priority on the CPU and
the GPU and holds background work back. The app's `Info.plist` declares a
games category, which is how macOS recognises a game. But the engine does not
run as the app's own process. The launcher starts it as a child, so that the
lobby can come back after an engine error. Nobody has checked that Game Mode
still turns on for it.

The check is at the screen. Start a game in full screen and look for the Game
Mode item in the menu bar.

### The Metal Layer Allows Reads of Its Drawables

`MetalPresent.mm` sets `framebufferOnly = NO` on the layer so that a drawable
can be the target of a blit. Only the CPU staging path blits into a drawable,
and that path is used by the legacy present and a diagnostics test. The
direct path and the IOSurface path draw with a render pass, which works with
`framebufferOnly = YES`. Apple's documentation says Core Animation can
optimise the drawables for display when that is set.

The change is small: set it to `YES` and have the staging path draw with a
render pass too. The gain is probably small as well, and it is not measured.

### A Present With No Readback

If the engine's framebuffer were rendered straight into the surface Metal
draws, there would be no readback at all. It is the largest gain left in the
present path, and it is blocked on upstream Mesa work. KosmicKrisp's
`VK_EXT_external_memory_metal` would need to handle IOSurface or Metal texture
handles, and Zink would need a way to use the resulting image as a framebuffer
attachment.

This was checked again at Mesa 26.3.0 on 2026-11-17. KosmicKrisp still handles
Metal heap handles only, Zink has no Metal window surface, and Mesa's EGL has
no macOS window platform.

### Late-Game Frame Rate

In large late-game battles the limit is the simulation and game Lua on the
main thread. That is a property of the engine, not of the graphics stack.

### The Cost of Restart on List Topologies in KosmicKrisp

The driver advertises the feature and pays for it with a compute pass per
draw. Whether it should is a question for upstream, see
[UPSTREAM.md](UPSTREAM.md).
