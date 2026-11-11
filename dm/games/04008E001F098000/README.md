# Nintendo Switch Sports Resort (`04008E001F098000`)

A Switch 2 game: update v65536, which holds the whole game (packed from a NUP with no base game and no control data). Nintendo EPD's sead / agl / gsys with Havok, SDK 22.2.10 built for the Switch 2 (Ounce), NVN2. Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`; `subsdk1` to `subsdk4` are not loaded. On the Mac it boots, goes through the menus and plays a doubles tennis match at 60 fps. Not run on an iPhone or iPad.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x2000000` | [`game.tsv`](game.tsv) | the NPDM's 32 MB of system resource: virtual address memory |
| `mem_reserve 0x318000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x240000000` | `game.tsv` | the Switch 2's 9 GB pool, and the 7.47 GB heap the game asks for (the NSP script's heap check). In its first 15 s the game's regions reach alias +1.09 GB; in play +3.26 GB was seen |
| `depth_mode zero` | `game.tsv` | the game calls `nvnDeviceSetDepthMode` with near = 0, so the pipeline bases made before it runs take that mode |
| `render_cond on` | `game.tsv` | the game wraps clears in render conditions; with the key about 10 redundant clears a frame are skipped, with no visible change. See [Rendering](#rendering) |
| `pso_manifest.tsv`: 31 `M` rows | [`pso_manifest.tsv`](pso_manifest.tsv) | the native task / mesh pipelines, which the offline pipeline archive does not hold. See [Pipelines](#pipelines) |
| `DM_ROMFS_OVERLAY` with patched resource size tables | the player's `env.txt` (outside the repository) | a stopgap for the model heaps the host's command records overrun: [Model heaps sized by the host's command record sizes](../../../docs/reference/memory.md#model-heaps-sized-by-the-hosts-command-record-sizes) (open) |

## Pipelines

- Build the Mac app with its pipeline archive (the NSP script's default; `--gpu none` leaves it out): 10,784 bases and 291 compute pipelines, 590 MB (M2 Max). Without it every new draw waited for its pulling base. In one 13-minute session with no archive and `DM_PSO_PREBUILD=0`, 247 new pipelines stalled frames for 23.3 s in all, the worst 5.7 s at the start of a match (`draws that waited: pulling base not made yet 110 / 5973 ms`). With the archive, on the same device lists, no long frame had a new pipeline.
- `pso_manifest.tsv` lists only the 22 task / mesh pipelines the device's own list recorded over boot, the menus and several sports: the offline archive holds no task / mesh pipeline. On a first start (no `pso_user.tsv`, no device archive, the same 110 s route) the list prepares in 0.01 s, and the 18 task / mesh pipelines the route meets are no longer built at their first draw (0.1-1.1 ms each here, with the Metal shader cache warm; a cold cache, where Ocarina of Time's took seconds, is not measured). The device's whole list (5,698 rows) as the seed instead spent 19.4 s preparing before the first frame, compiling 1,376 bases with a vertex layout the offline archive does not hold; without it the first 110 s of play built about 200-220 render pipelines, about 0.3 s spread over the long frames, while hybrid pipelines drew. A 37-minute session on 2026-11-11 (app with the full offline archive, b6ddedf1) still built 9 task / mesh pipelines the list lacked at their first draw, all with task shader `ffb46e1e142722c3_b` but two: 65-800 ms each, 1.7 s in one frame of a sport's load (frame 51,749); the list now holds them too (31 rows).
- A few compute shaders take Apple's compiler minutes: [A compute pipeline that takes minutes to build stops the replay](../../../docs/reference/shaders.md#a-compute-pipeline-that-takes-minutes-to-build-stops-the-replay). They come from the archive now.

## Frame rate

- **60 fps, present interval 1.** In the tennis match (M2 Max, window, 240 Hz screen): frame time p50 16.67 / p95 17.2 ms, NVN submit about 6.8 ms and GPU about 12 ms a frame, CPU about 145% of one core, no frame dropped on screen. The game sets interval 2 for a few frames around scene loads.
- **Scene loads.** The first frame of a scene draws every texture the scene loaded: 855 textures (908 MB) for the court behind the sport menu, 224-232 ms, nearly all of it on the submit thread, about 150 ms of it committing the residency set: the new textures, their staging and their source buffers, about 0.04 ms per MB while the GPU runs the previous frames ([Two source buffers for each staged upload from a large pool](../../../docs/reference/memory.md#two-source-buffers-for-each-staged-upload-from-a-large-pool), [Residency changes waited for another thread's commit](../../../docs/reference/memory.md#residency-changes-waited-for-another-threads-commit)). Smaller loads: 92 textures about 110 ms, 340 about 135 ms. Making the textures when the game registers them removed the court frame's hitch, but the game registers about 13,800 packaged textures at boot that it never draws (GPU memory 3.0 → 6.5 GB), so the host does not do that.
- **Boot.** One frame about 7 s in runs 250 ms on the GPU: the game draws 1,657 render passes in it, 400 of them one-draw 256x32 RGBA16F passes of up to 1.8 ms each. The next frame waits for it.
- **When measuring:** a run's screenshots (`DM_NVN_SHOT`) each cost a frame of 120-190 ms. On a 75 Hz screen (seen in unattended runs) 60 fps shows as one frame of 26.7 ms in every four, by the screen's rate, not the game. Heavy compiles beside the game (an offline pipeline archive build) took a session from 60 to 22-40 fps: the game's main thread spins on its workers, which then lack CPU.

## Rendering

- `render_cond on`: about 10 clears a frame are conditional on render-enable state the game sets; with the key they are skipped as on the console. No visible change in the menus and the match.
- Resolved (chain 592225da745b): the main menu's island sea drew black with NaN noise, and the avatar's hair and clothes drew flat black in Personalizar, user selection and the HUD icons. Both were the [fragment size register read as 0](../../../docs/reference/shaders.md#the-fragment-size-register-special-register-0x84-reads-1-x-1): the sea shaders `01a6b85e2f6ea3d4`, `b3203175c76cda20` and `2271b2e0293b3c55` divided by it, and the avatar material `c30f0edd6c669a61` took it into a shading factor. On the rebuilt app the sea is blue and two random default avatars show their colours in Personalizar (`DM_CTL` route, runs of 2026-11-10 15:11 and 15:15).
- Open: six mesh shaders are refused (task payloads over Metal's 16 KB), never loaded in the runs so far.
- **Picture size.** Docked (the host's default, graphics scale tier 0) the game's output is 2560x1440. Its dynamic resolution steps between 2560x1440 (no upscale) and 854x480, through 2134x1200, 2048x1152, 1862x1048, 1707x960, 1536x864, 1494x840, 1397x786, 1280x720 and 1164x655, and agl's NDSR network upscales to 2560x1440 (`DM_UPSCALER=metalfx`: MetalFX's spatial scaler instead). At full size its frame has stair-stepped edges of its own (the pointer calibration screen's swapchain texture; its pass dump has no multisampled target).
- A picture shown smaller than 2560x1440 (fullscreen on a 1080p screen, a window) went through one bilinear tap a pixel, which made the steps uneven; resolved, [A picture shown smaller than it is drawn](../../../docs/reference/rendering.md#a-picture-shown-smaller-than-it-is-drawn-stair-stepped-edges-from-the-presents-single-tap).
- Open, **dynamic resolution at its floor for nothing** (M2 Max, pointer calibration screen, `DM_UPSCALER=game`, one 150 s run; the log's `game upscaler input over 600 presents` line): most 600-present windows render at full size at a GPU p50 of about 12.4 ms, then the game drops to 854x480-1280x720 for 600 presents and more (a window counted 333 frames at 854x480) while the GPU p50 stays 12.2-12.4 ms. Its cost hardly follows the resolution on this Mac, as on [Ocarina of Time](../0400486024DEC000/README.md#dynamic-resolution), so stepping down saves nothing and the picture is upscaled from a quarter of the pixels or less. The player's session log of 2026-11-11 has the same sweeps: MetalFX scalers made again and again for every size down to 854x480. Its controller (agl / gsys, parameters `DensityDrc`, `LowerResolutionFrame`, `IsEnableLowerResolutionByCrash` among the strings) is not located yet; a stub that holds full size, as Ocarina's, is the likely fix.

## Memory

- In the tennis match: resident (footprint) about 9.7 GB, GPU allocated 5.6-8 GB.

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac` and use its printed command.
- From an existing save: `DM_KEYS="20:A*60/3"` (A every 3 s from 20 s) goes through the menus into a doubles tennis match, at its serve prompt by about frame 5,000.

## Open

- The model-heap overrun and its `DM_ROMFS_OVERLAY` stopgap ([memory](../../../docs/reference/memory.md#model-heaps-sized-by-the-hosts-command-record-sizes)).
- The shader defects above.
- Motion controls: only the sensor-fusion service path is checked ([Switch 2 hid calls that open the hid service](../../../docs/reference/services.md#switch-2-hid-calls-that-open-the-hid-service)); a match played with motion input is not.
- Sports other than tennis are not checked in a scripted route.
- The 225 ms first frame of the court and the other scene loads; the boot frame.
- iPhone and iPad: no IPA built.

## Found on this game

- [A controller in a style the game does not support](../../../docs/reference/services.md#a-controller-in-a-style-the-game-does-not-support)
- [Switch 2 hid calls that open the hid service](../../../docs/reference/services.md#switch-2-hid-calls-that-open-the-hid-service)
- [Home button protection on a Switch 2 controller](../../../docs/reference/services.md#home-button-protection-on-a-switch-2-controller)
- [File calls on a mount in the SDK's own table](../../../docs/reference/services.md#file-calls-on-a-mount-in-the-sdks-own-table)
- [A read-only mount of the game's own save data](../../../docs/reference/services.md#a-read-only-mount-of-the-games-own-save-data)
- [The output device notification under its SDK 21 and 22 name](../../../docs/reference/audio.md#the-output-device-notification-under-its-sdk-21-and-22-name)
- [The virtual output device's properties, and the OutputStream open without flags](../../../docs/reference/audio.md#the-virtual-output-devices-properties-and-the-outputstream-open-without-flags)
- [A render-target view of another class: the texture is upgraded, not drawn in its base format](../../../docs/reference/rendering.md#a-render-target-view-of-another-class-the-texture-is-upgraded-not-drawn-in-its-base-format)
- [A compute pipeline that takes minutes to build stops the replay](../../../docs/reference/shaders.md#a-compute-pipeline-that-takes-minutes-to-build-stops-the-replay)
- [One group that metal-tt cannot finish costs the whole archive](../../../docs/reference/shaders.md#one-group-that-metal-tt-cannot-finish-costs-the-whole-archive)
- [Model heaps sized by the host's command record sizes](../../../docs/reference/memory.md#model-heaps-sized-by-the-hosts-command-record-sizes)
- [Two source buffers for each staged upload from a large pool](../../../docs/reference/memory.md#two-source-buffers-for-each-staged-upload-from-a-large-pool)
- [The fragment size register (special register 0x84) reads 1 x 1](../../../docs/reference/shaders.md#the-fragment-size-register-special-register-0x84-reads-1-x-1)
- [A picture shown smaller than it is drawn: stair-stepped edges from the present's single tap](../../../docs/reference/rendering.md#a-picture-shown-smaller-than-it-is-drawn-stair-stepped-edges-from-the-presents-single-tap)
