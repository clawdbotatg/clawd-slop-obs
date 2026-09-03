# clawd-slop-obs

The reproducible slop.computer show rig: OBS config + the parameterized
launcher that puts a live room on stream.

- **`INSTALL.md`** — first-time setup on a new machine (OBS config, stream
  key from the USB stick, macOS permissions).
- **`RUNBOOK.md`** — show-night operations: the launch ritual, the full
  gesture pipeline (eye detector → relay → room page → OBS), and the
  symptom → fix debugging table. Start here if something is broken.
- **`run-show.sh`** — the per-show launcher:
  `./run-show.sh 'https://live.slop.computer/<room>?invite=<tok>&godMode=<tok>'`
