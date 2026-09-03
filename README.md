# OmaStats

A system monitor for the [Omarchy](https://omarchy.org) bar, in the spirit of
Bjango's [iStat Menus](https://bjango.com/mac/istatmenus/): CPU, GPU, memory,
disk, network, temperatures, fans and battery stats at a glance. Compact readouts with
live mini graphs sit in the bar; clicking one opens a panel with history graphs,
ring gauges, sensors and the top processes, one tab per module. Everything it
shows, in the bar and in the panel, is configurable from inside the panel.

OmaStats is an independent project and is not affiliated with Bjango.

![OmaStats: a system monitor for the Omarchy bar](preview.png)

![Memory, Network, Sensors and Settings pages](preview-pages.png)

## Modules

| Module  | Bar readout                         | Panel                                                                 |
|---------|-------------------------------------|-----------------------------------------------------------------------|
| CPU     | glyph · user/system history · %     | User/system history, per-core rings, load, uptime, GPU, top processes |
| GPU     | glyph · utilisation history · %     | Shown on the CPU page (NVIDIA via `nvidia-smi`, AMD/Intel via sysfs)  |
| Memory  | glyph · used history · %            | Swap and memory rings, breakdown, processes                           |
| Disks   | glyph · read/write history · rates  | Volumes (click to open in Files), activity for all disks or one, processes |
| Network | glyph · up/down history · rates     | Upload/download, interfaces, public and local IPs, traffic per process |
| Sensors | any temperatures and fans you pick  | CPU/GPU/fan rings, every hwmon temperature and fan                    |
| Battery | glyph by level · %                  | Charge and health rings, charge history, power, cycles, peripherals   |

Battery and GPU only appear when the hardware exists.

## Install

```bash
omarchy plugin add https://github.com/crmne/omastats.git --enable
```

Or by hand: copy this directory to `~/.config/omarchy/plugins/crmne.omastats/`, then
`omarchy plugin enable crmne.omastats`.

## Remove

```bash
omarchy plugin remove crmne.omastats
```

That disables the plugin and deletes its directory. By hand:
`omarchy plugin disable crmne.omastats`, then remove
`~/.config/omarchy/plugins/crmne.omastats/`. Nothing is written outside that
directory except this widget's own entry in `~/.config/omarchy/shell.json`,
which `omarchy plugin disable` removes.

## What it needs

The plugin runs one small sampler process that reads procfs and sysfs. Two
implementations ship with the same JSON protocol:

- `bin/omastats-sampler` — a Rust binary, x86-64, about 3 MB resident and 0.3% CPU.
  Built from `sampler/`; run `make` to rebuild it for your machine. Its checksum,
  byte-for-byte reproducible build, and signed GitHub attestation are documented
  in [BINARY_PROVENANCE.md](BINARY_PROVENANCE.md).
- `sampler.py` — a Python 3 fallback used whenever that binary is missing or
  cannot run here (another architecture, for instance). No third-party modules.

Optional command-line tools, each used only for the feature named, and each
degrading to "unavailable" when missing: `nvidia-smi` (NVIDIA GPU readings;
AMD and Intel come from sysfs), `ip` and `iw` (addresses, Wi-Fi signal),
`ss` from iproute2 (per-process network traffic), `curl` (public IP lookup),
`wl-copy` (copy an address), `xdg-open` (open a volume in your file manager).

Nothing runs as root, and no data leaves the machine except the optional
public-IP lookup, which you can switch off in Settings. That lookup tries
`api.ipify.org`, `icanhazip.com`, then `ifconfig.me` over HTTPS and stops after
the first valid IP-address response.

`make` builds the binary and checksum into `bin/`; `make verify-binary` performs
two clean builds and compares them with the bundled artifact. `make install`
syncs the plugin into the Omarchy plugin directory.

## Configuring

Open the panel and click the gear at the right end of the tab strip (or press `s`).

- **Bar**: switch each module's readout on or off, order them with the arrows,
  and pick each one's look: a mini history graph, a fullness ring (CPU, GPU,
  memory, disk capacity, battery charge), a figure, or a graph or ring with the
  figure. The Disks readout can follow all disks or one device; the Sensors
  readout shows whichever temperatures and fans you tick.
- **Panel**: choose which tabs appear and which sections each page shows.
- **General**: temperature unit, refresh interval (0.1 s to 10 s), history span,
  bar graph width, and a reset.

Every process list has an **All** toggle that unfolds into every process with a
search field (`/` from anywhere in the panel), sorted by that page's column.

Changes are written to this widget's entry in `~/.config/omarchy/shell.json`, so
they survive restarts and each bar instance keeps its own. The same keys can be
edited there by hand or through Setup → Plugins:

| Key                       | Default                                   | Meaning                                                   |
|---------------------------|-------------------------------------------|-----------------------------------------------------------|
| `modules`                 | `cpu,memory,network`                      | Bar readouts, in order: `cpu gpu memory disks network sensors battery` |
| `style`                   | `both`                                    | Default look of a readout: `graph`, `ring`, `text`, `both` (graph and figure), or `ring-text` |
| `cpuStyle` … `batteryStyle` | *(inherit)*                             | Per-module override of `style`                            |
| `tabs`                    | `cpu,memory,disks,network,sensors,battery` | Tabs shown in the panel                                  |
| `graphWidth`              | `36`                                      | Width of each mini graph in the bar                       |
| `barLabels`               | `text`                                    | `text` stacks the module's letters vertically, `icon` uses glyphs |
| `disksSource`             | `all`                                     | Disk readout and activity graph: `all` or a device like `nvme0n1` |
| `barSensors`              | `cpu`                                     | Sensor readouts: `cpu`, `gpu`, or hwmon ids like `nct6687/fan1` |
| `temperatureUnit`         | `Celsius`                                 | `Celsius` or `Fahrenheit`                                 |
| `refreshSeconds`          | `1`                                       | Sampling interval: 0.1, 0.2, 0.5, 1, 2, 5 or 10           |
| `historySeconds`          | `240`                                     | How far back the graphs reach, in seconds                 |
| `publicIp`                | `true`                                    | Look up the public address (api.ipify.org) on the Network page |
| `showProcesses`           | `true`                                    | Top processes on every page                               |
| `showCores`, `showLoad`, `showGpu` | `true`                           | CPU page sections                                         |
| `showBreakdown`           | `true`                                    | Memory breakdown                                          |
| `showVolumes`, `showActivity` | `true`                                | Disks page sections                                       |
| `showInterfaces`, `showTotals`, `showAddresses` | `true`              | Network page sections                                     |
| `showTemperatures`, `showFans` | `true`                               | Sensors page sections                                     |
| `showHistory`, `showDetails`, `showDevices` | `true`                  | Battery page sections                                     |

Several instances are allowed, so modules can be spread across the bar:

```json
{ "id": "crmne.omastats", "modules": "cpu,memory" },
{ "id": "crmne.omastats", "modules": "network", "networkStyle": "graph" }
```

## Interaction

- **Left click** a readout opens its page; clicking the same readout again closes the panel.
- **Right click** launches `btop`. **Middle click** refreshes the public IP.
- In the panel: `h`/`l` or `←`/`→` switch tabs, `1`–`6` jump to a tab, `s` opens
  Settings, `/` searches processes, `j`/`k` scroll, `Tab` moves to the neighbouring
  bar panel, `Esc` closes, `r` refreshes.
- Addresses on the Network page copy to the clipboard when clicked. Volumes on
  the Disks page open in the file manager.

The sampler reads cheap counters at the chosen interval and everything that
walks many files (processes, sensors, battery, socket mapping) at most once a
second, so 0.1 s refresh stays inexpensive. Per-process network traffic comes
from the kernel's per-socket TCP byte counters (the same ones `ss -ti` shows),
differenced once a second and tied to processes through `/proc`, so it needs no
root. UDP, and therefore QUIC, carries no such counters and is not attributed.

IPC:

```bash
omarchy-shell crmne.omastats show sensors    # open on a tab (or "settings")
omarchy-shell crmne.omastats toggle network
omarchy-shell crmne.omastats hide
omarchy-shell crmne.omastats status          # JSON summary
```

## Design notes

Graph colours come from the active theme: the accent is the first series and the
theme colour furthest around the hue wheel (magenta, cyan or blue preferred) is the
second, so user/system, upload/download and read/write always read as a pair in
any theme. Warnings use the theme's yellow and red. Text never wears a data colour;
identity comes from the dot beside it.

The tab strip gives every module an equal slot, the settings gear included, so
nothing shifts when you switch, and the panel sizes itself so every tab is
named in full. Abbreviations live only in the bar, where height is scarce:
the readouts stack the module's letters (CPU, MEM, DSK, NET) the way iStat
Menus labels its menubar items, unless you prefer glyphs.

## License

MIT
