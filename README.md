```
     _   _ _       _     _     _       _     _       _
    | \ | (_)     | |   | |   | \     / |   | |     | |
    |  \| |_  __ _| |__ | |_  \  \ _ /  /_ _| |_  __| |___
    | . ` | |/ _` | '_ \| __|  \  ` '  / _` | __|/ _| '_  \
    | |\  | | (_| | | | | |_    \     / (_| | |_| (_| | | |
    |_| \_|_|\__, |_| |_|\__|    \_|_/ \__,_|\__|\__|_| |_|
              __/ |
             |___/
                   T H E   N I G H T   W A T C H
```

![nightwatch](docs/nightwatch.png)

> The city sleeps.
> The files do not.

"FABRICATI DIEM, PVNC"

**The Night Watch** is a file change tracker for directory trees, written
in **Zig**.

It provides:

- A standalone CLI for tracking filesystem changes
- A module for embedding change-tracking into other Zig programs
- Minimal dependencies and consistent, predictable, cross-platform behavior

It does not interfere.
It does not speculate.
It simply keeps watch.

---

## Features

- Recursive directory tree tracking
- Deterministic multi-platform support (Linux, macOS, FreeBSD, OpenBSD, NetBSD, DragonFly BSD, Windows)
- Lightweight and fast
- Embeddable Zig module API
- Standalone CLI executable

### Platform backends

| Platform                                | Backend                                                | Notes                              |
| --------------------------------------- | ------------------------------------------------------ | ---------------------------------- |
| Linux                                   | inotify                                                | Threaded (default) or polling mode |
| macOS                                   | kqueue (default) or FSEvents (`-Dmacos_fsevents=true`) | FSEvents requires Xcode frameworks |
| macOS                                   | kqueue dir-only (`.kqueuedir` variant)                 | Low fd usage; see note below       |
| FreeBSD, OpenBSD, NetBSD, DragonFly BSD | kqueue (default)                                       |                                    |
| FreeBSD, OpenBSD, NetBSD, DragonFly BSD | kqueue dir-only (`.kqueuedir` variant)                 | Low fd usage; see note below       |
| Windows                                 | ReadDirectoryChangesW                                  |                                    |

#### `kqueuedir` variant

By default the kqueue backend opens one file descriptor per watched _file_
in order to detect `modified` events in real time via `EVFILT_VNODE`. At
scale (e.g. 500k files) this exhausts the process fd limit.

Use `nightwatch.Create(.kqueuedir)` to select directory-only kqueue watches
instead. This drops fd usage from O(files) to O(directories). The trade-off:

- **`modified` events are not generated reliably.** The backend detects
  file modifications opportunistically by comparing mtimes during a
  directory scan, which only runs when a directory entry changes (file
  created, deleted, or renamed). A pure content write to an existing file
  with no sibling changes will not trigger a scan and the modification will
  be missed until the next scan.

- **Workaround:** Watch individual files directly (e.g.
  `watcher.watch("/path/to/file.txt")`). When a path passed to `watch()` is
  a regular file, the `kqueuedir` variant attaches a per-file kqueue watch
  and emits real-time `modified` events exactly like the default backend.
  Only _directory tree_ watches are affected by the limitation above.

---

# Installation

The Watch is written in **Zig** and built using the Zig build system.

## Requirements

- Zig (currently zig-0.15.2)

## Build CLI

```bash
zig build
```

The executable will be located in:

`zig-out/bin/nightwatch`

## Install System-Wide

```bash
zig build install
```

---

# Using as a Zig Module

The Night Watch exposes a reusable module that can be imported into
other Zig programs.

In your `build.zig`:

```zig
const nightwatch = b.dependency("nightwatch", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("nightwatch", nightwatch.module("nightwatch"));
```

In your Zig source:

```zig
const nightwatch = @import("nightwatch");
```

You now have programmatic access to the tracking engine.

---

# CLI Usage

```bash
nightwatch [--ignore <path>]... <path> [<path> ...]
```

Run:

```bash
nightwatch --help
```

for full command documentation.

---

# Philosophy

Other tools watch files.

The Night Watch keeps watch over the peace.

It remembers what changed.
It records what vanished.
It notices what arrived at 2:14 AM.

And it writes it down.
