# gym-simulator

A Roblox gym-training game in the vein of **Gym League**, with one differentiating hook taken
from **Super Power Training Simulator**: PvP is live inside the gym. Players can attack each
other mid-training-set, breaking rep combos to annoy them.

Build progress is tracked in [`CHECKLIST.md`](CHECKLIST.md) — 60 numbered items across 10
phases. Architecture rules live in [`CLAUDE.md`](CLAUDE.md).

## Setup

Tooling is managed by [Rokit](https://github.com/rojo-rbx/rokit) and dependencies by
[Wally](https://wally.run). After cloning:

```bash
rokit install     # rojo, wally, stylua, selene, luau
wally install     # populates Packages/ and ServerPackages/
```

`wally install` is required before the first build — `default.project.json` mounts both
package directories.

## Development

```bash
rojo build -o gym-simulator.rbxlx   # build a place file from scratch
rojo serve                          # then connect from the Rojo Studio plugin
```

Open `gym-simulator.rbxlx` in Roblox Studio and start the Rojo server to live-sync.

## Checks

```bash
./scripts/check.sh         # formatting, lints, and --!strict type analysis
./scripts/check.sh --fix   # same, but applies StyLua formatting
```

That runs StyLua, Selene, and `luau-lsp analyze` against a freshly generated Rojo
sourcemap, which is what actually enforces the `--!strict` rule outside Studio. It fetches
the Roblox type definitions into `.luau-defs/` on first run.

Individual tools, if you want them separately:

```bash
selene src
stylua --check src
```

Pure modules that touch no Roblox API can be self-tested without Studio. `NumberFormat` and
`Formulas` both expose `RunSelfTest()`:

```bash
luau path/to/script.luau
```

`NumberFormat.RunSelfTest()` also runs automatically from the server bootstrap in Studio.

## Layout

| Path | Contents |
|---|---|
| `src/ServerScriptService/Core/` | Server systems, auto-loaded by `Loader` |
| `src/ReplicatedStorage/Modules/` | Shared modules — `Loader`, `Net`, `Types`, `NumberFormat`, configs |
| `src/StarterPlayer/StarterPlayerScripts/Controllers/` | Client controllers, auto-loaded by `Loader` |

Adding a system means dropping a file into `Core/` or `Controllers/`. There is no registration
list — see the open/closed rule in `CHECKLIST.md`.
