# OmaStats launch video

The source of the launch video: a [HyperFrames](https://hyperframes.heygen.com)
composition (`index.html`) that rebuilds the bar readouts and panel pages in
HTML at the widget's own sizes, plus a synthesized soundtrack
(`soundtrack.py`). Everything on screen is demo data; `plan.md` has the
storyboard.

The rendered video is attached to the GitHub release rather than committed.
This directory is not part of the plugin: `make install` leaves it out.

## Render

Needs Node.js 22 or newer, FFmpeg, and Python 3 with NumPy.

```bash
cd video
python3 soundtrack.py assets/soundtrack.wav   # 51 s, deterministic
npx --yes hyperframes@0.8.82 check            # lint, layout and contrast
npx --yes hyperframes@0.8.82 preview          # scrub it in the browser
npx --yes hyperframes@0.8.82 render --fps 30 --quality delivery --output renders/omastats.mp4
```

The fonts in `assets/fonts` are subsets of JetBrains Mono Nerd Font and Inter,
both under the SIL Open Font License (license texts alongside).
