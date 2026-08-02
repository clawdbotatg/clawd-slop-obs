# Installing the show rig on a new machine

Everything reproducible lives in this repo. The **one secret** — the RTMP
stream key (`service.json`) — lives on the "NO NAME" USB stick under
`slop-credentials/`, and must never be committed (`.gitignore` enforces this).

## Steps

1. Install [OBS](https://obsproject.com) and Google Chrome (standard
   `/Applications` locations).
2. Clone / pull this repo.
3. Insert the "NO NAME" USB stick.
4. Run `./install.sh` — it copies `obs-config/` into
   `~/Library/Application Support/obs-studio/`, finds the stream key on the
   stick automatically, and sanity-checks the result. (Or pass the key
   explicitly: `./install.sh /path/to/service.json`.)
5. Grant macOS permissions (System Settings → Privacy & Security):
   - **Screen & System Audio Recording** → OBS — window capture renders black
     without it.
   - **Accessibility** → whatever terminal/daemon runs `run-show.sh` — the
     script positions windows via System Events.
6. Test a show:
   ```
   ./run-show.sh 'https://live.slop.computer/<room>?invite=<tok>&godMode=<tok>'
   ```
   Log: `/tmp/slopcomputer.log`. Expected: Chrome opens the room and is
   positioned, the script logs a nonzero `MAIN_ID`, OBS launches on the
   `Untitled` collection showing the room at 1920×1080.

## Caveats

- `run-show.sh` hardcodes `PROFILE_DIR=/Users/clawd/.openclaw/browser/openclaw/user-data`
  — fine when the machine's user is `clawd`; otherwise edit the CONFIG block.
  Chrome creates the profile fresh on first run; no logins needed (the
  room/invite/godMode tokens ride in the show URL).
- Window bounds assume a display of at least ~1771×1075 points. On a smaller
  screen, shrink the geometry numbers in the CONFIG block.
- The show tokens in the URL are per-show secrets too — they're arguments,
  never committed.

## What's where

| Piece | Location | In git? |
|---|---|---|
| `run-show.sh` (launcher) | repo root | yes |
| OBS scenes + profile + encoder settings | `obs-config/` | yes |
| Stream key (`service.json`) | USB stick → `~/Library/…/profiles/Untitled/` | **never** |
| Show URL tokens (invite/godMode) | argument to `run-show.sh`, minted per show | never |
