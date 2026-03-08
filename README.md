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
- Deterministic multi-platform support (Linux, FreeBSD, MacOS, Windows)
- Lightweight and fast
- Embeddable Zig module API
- Standalone CLI executable

------------------------------------------------------------------------

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
nightwatch [{path}..]
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
