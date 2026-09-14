# Show-night runbook — the full rig, for the next operator (human or agent)

This is the handoff document: everything needed to launch, verify, and debug a
slop.computer show from this machine, written assuming you remember nothing.
`INSTALL.md` covers first-time machine setup; this covers *operating* it.
Verified end-to-end on 2026-08-31 (room `kassandraeth`).

## The big picture

A show is just: **one Chrome window showing the live room page, captured by
OBS, streamed out.** Everything else exists to make that window correct and to
get hand gestures into it.

```
your hands on camera
  → room page camera feed (live.slop.computer/<room>)
  → SLOP-EYE Chrome window    (?fx=0 view; run-show opens it behind the main
                               window at the same bounds; the page lays every
                               camera out LARGE + uncropped — EyeStage.tsx)
  → slop-detector             (this Mac; screen-captures the eye window,
                               Apple Vision hand-pose, 10 fps, ≤6 hands)
  → POST 21 landmarks/hand → https://live.slop.computer/v1/hands
                               (auth: X-Gesture-Key = god password)
  → relay classifies the pose  (slop-computer-live repo, packages/relay/src/gestures.ts)
       open palm (4–5 fingers)              → hold ETH diamond, tracks hand
       fist (0–1 fingers)                   → release → float-away flight
       thumb+index+middle, ring+pinky curled → CLAW 🦞 (pinch = pincer open/close)
  → room page renders shapes   (GestureLayer.tsx — in a lazy-loaded Next.js
                               chunk; clone the repo to grep it, the initial
                               HTML's chunk list won't contain it)
  → OBS window-captures the room page → stream
```

Key consequence: **there is no local foreground/green-screen rig in this
flow.** The OBS `Untitled` collection captures exactly one window (the room
page) plus two audio sources and the teleprompt scene. Gestures reach the
stream because the room page itself draws them. The older Rig2 setup
(foreground.html, slop-server on :9911, in the `slop-computer-background`
repo) is NOT used and need not be running.

## Per-show ritual (order matters)

1. **Launch the show:**
   ```
   ./run-show.sh 'https://live.slop.computer/<room>?invite=<tok>&godMode=<tok>'
   ```
   Each show gets a fresh URL (room + invite + godMode tokens — per-show
   secrets, never committed). The script self-detaches (survives the caller
   closing), quits ALL Chrome + OBS, relaunches Chrome on the show URL,
   positions it to 1706×1045, reads the fresh CGWindowID, patches it into the
   OBS `Untitled` collection's window-capture source, opens the EYE window
   (same URL + `&fx=0`) at the same bounds behind the main window, forces
   1080p, launches OBS, re-asserts OBS geometry, asks the relay what eye
   geometry it sees, and last opens the EQ window
   (`live.slop.computer/eq?slug=<room>`, slug taken from the show URL) as a
   third Chrome window, on top, sized once to 640×1000 at the left edge.

   Watch `/tmp/slopcomputer.log` until the `Done.` line. A healthy run logs a
   nonzero `MAIN_ID`, `set window=<id> on 1 source(s)`, a nonzero `EYE_ID`,
   `relay: eye viewport WxH, N camera(s) visible to the detector`, and
   `eq page is up.`

2. **The 👁 button is now a fallback only.** run-show opens the eye. If you
   ever need to reopen it by hand, click 👁 in the god-mode menu bar — it
   opens at the god window's viewport size. Never open it *before*
   run-show: the script quits all of Chrome.

3. **The EQ window is opened by run-show too** (since 2026-09-14). The
   script gives it one initial size (640×1000: narrow and tall, so the
   master bands, amp, sources and video panels are all visible) and never
   touches it again; drag it wherever you like. **Why the size matters:** at
   the room window's size the page's stream preview fills the whole
   viewport and the EQ sliders sit below the fold, so it looks like a black
   "second video monitor" (this bit a live show on 2026-09-14). If the log
   says `WARNING: EQ window did not appear`, open
   `live.slop.computer/eq?slug=<room>` by hand in the same Chrome.

No permission dialogs should appear at any step once the machine is set up
(see "Standing machine state" below).

## Standing machine state (running always, survives reboots)

| Thing | Where | Notes |
|---|---|---|
| `slop-detector` binary | `../slop-computer-background/slop-detector` | Built by `slop-eye-install.sh` from that repo (sibling clone) |
| launchd agent | `~/Library/LaunchAgents/com.slop.eye.plist`, label `com.slop.eye` | RunAtLoad + KeepAlive; args: `Chrome`, `SLOP-EYE`, the relay /v1/hands URL |
| God password | gitignored `../slop-computer-background/.slop-eye.env` AND the plist's `SLOP_GESTURE_KEY` env var | Same secret as the show URL's `godMode` token (`slop-eye.sh` proves it: it builds `godMode=$SLOP_GOD_PASSWORD`) |
| Detector log | `/tmp/slop-eye-detector.log` | The primary health signal |
| Screen Recording TCC | granted to the `slop-detector` binary | Granted manually once; see failure modes |
| OBS Screen Recording + terminal Accessibility | per INSTALL.md | |
| Stream key | `~/Library/Application Support/obs-studio/basic/profiles/Untitled/service.json` | From the "NO NAME" USB stick; never in git |

The detector does **hands only** — despite the name there is no eye/face/gaze
tracking; the sole Vision request is `VNDetectHumanHandPoseRequest`. "Eye" is
the rig's eye on the room. Close the SLOP-EYE window → gestures stop; open it
in another room → gestures follow.

## Debugging: symptom → cause → fix

Start with `tail /tmp/slop-eye-detector.log` and `tail /tmp/slopcomputer.log`.

**`hands: N [left,right]` lines** — detector pipeline is alive. If shapes
still don't render, the problem is downstream (stale god key, or the room
page — see below).

**`(no match yet) — retrying`** — no Chrome window titled SLOP-EYE exists.
The 👁 window isn't open, or run-show just killed it. Click 👁 (after
run-show).

**`The user declined TCCs for application, window, display capture`** —
Screen Recording permission is gone. Two causes:
- The binary was rebuilt (e.g. `slop-eye-install.sh` re-run) — macOS keys the
  grant to the binary hash, so a rebuild forgets it.
- The grant was toggled off.
Fix (human required, prompts cannot render from an agent shell — macOS
auto-declines there): System Settings → Privacy & Security → Screen
Recording → enable `slop-detector`, then
`launchctl kickstart -k gui/$(id -u)/com.slop.eye`.

**`relay: no eye open anywhere` / `no eye geometry yet` at the end of the
run-show log** — the eye page loaded but isn't reporting over its WS (didn't
get past a gate, or god auth didn't carry). Bring the eye window to the
front and look at it; it should show black with the camera tiles on it and
a `SLOP-EYE · <room> · N cams` stamp bottom-right (once the EyeStage deploy
is live; before that it shows a copy of the room).

**Detector healthy but no shapes on stream** — most likely a stale god key:
a new show URL carries a *different* `godMode` token and the relay silently
rejects the landmark posts (the detector does not log auth failures). Fix:
write the new token into `.slop-eye.env`, update `SLOP_GESTURE_KEY` in the
plist, then `launchctl unload` + `launchctl load` the plist. Cross-check on
the landmark monitor: https://live.slop.computer/v1/hands.html

**OBS shows black / the wrong window** — the window-capture source points at
a dead CGWindowID (window IDs die with the window; every Chrome relaunch
needs a re-patch). Re-run `run-show.sh` — patching the fresh ID is its whole
job. If it persists, OBS lost its own Screen Recording grant.

**Is it actually on stream? Don't trust the local page.** Screenshot the
exact window OBS captures:
```
screencapture -x -l <MAIN_ID> /tmp/check.png   # MAIN_ID from /tmp/slopcomputer.log
```
and look at the image. Whatever is in that frame is what viewers get.

**Detector process checks:**
```
launchctl list | grep slop.eye     # want: <pid>  0  com.slop.eye
```
Uninstall entirely: `launchctl unload ~/Library/LaunchAgents/com.slop.eye.plist && rm` it.

## Where the code lives

| Repo | What's in it |
|---|---|
| this repo (`clawd-slop-obs`) | `run-show.sh`, `install.sh`, `obs-config/` — the reproducible show rig |
| `clawdbotatg/slop-computer-background` | the eye: `slop-detector.swift`, `slop-eye-install.sh`, `slop-eye.sh`; plus the RETIRED Rig2 foreground rig (`hand-eth.html` there is a readable reference for the same gesture classification the relay uses) |
| `clawdbotatg/slop-computer-live` | the live site: relay gesture classification (`packages/relay/src/gestures.ts`), on-page rendering (`packages/nextjs/components/ui/GestureLayer.tsx`) |
