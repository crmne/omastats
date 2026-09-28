# OmaStats launch video plan

**What it is:** an iStat Menus-style system monitor for the Omarchy bar. Live mini graphs sit in the bar, and each readout opens a panel with history graphs, rings, sensors and top processes.
**For:** Omarchy users who want their machine's vital signs in the bar without opening btop.
**Sets it apart:** real graphs in the bar, a full panel behind every readout, colours that follow your theme, and a 3 MB Rust sampler.
**Most impressive claim:** refresh down to 0.1 s on about 3 MB and 0.3% CPU, plus network traffic per process with no root.
**Visual hook:** a bare bar coming alive, readout by readout, with graphs already ticking.
**Share caption:** iStat Menus, for the Omarchy bar.

Tone: `polished`, the bar as the hero. 1920x1080, 30 fps, 51 s (v2, after feedback: highlight the bar, behave like the real widget, show everything).
Built at the widget's real logical sizes (26 px bar, 36 px graphs of 1 px columns, fixed-width figures) and framed by a camera.

## Storyboard (v2)

| Time | Scene |
|---|---|
| 0 to 3.5 | Macro close-up of the CPU readout (9.6x), 1 px columns ticking. "Your machine's vital signs." Pull back to the whole bar. |
| 3.5 to 12.2 | "Live in the Omarchy bar." The camera glides readout by readout (4.2x): CPU, GPU, VRAM, memory, disks, network, sensors, battery, with a callout for each. |
| 12.2 to 13.8 | Whole bar with each figure's reserved width outlined: "Every figure keeps its width." |
| 14.0 to 18.4 | One readout cycling through its looks (Graph and figure, Graph, Ring, Ring and figure, Figure), then Letters to Icons. |
| 18.4 to 21.1 | New in 1.4: a vertical bar with data. |
| 21.1 to 42.0 | Click CPU, the panel opens; every tab in turn with the keyboard (CPU, GPU, Memory, Disks, Network, Sensors, Battery, Settings scrolling). |
| 42.0 to 45.4 | Pull back to the desktop; Tokyo Night, Gruvbox, Rosé Pine Dawn. |
| 45.4 to 51.0 | OmaStats lockup, install command, GitHub URL. |

Sound: numpy-synthesized A minor at 112.5 BPM, groove from 3.5 s, breakdown under the looks section, back in with the panel; effects in key on every cut. -14.3 LUFS, -1 dBFS peak.
