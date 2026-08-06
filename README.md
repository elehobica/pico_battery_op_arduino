# pico_battery_op (Arduino library)

Arduino port of the [pico_battery_op](https://github.com/elehobica/pico_battery_op) power-management
library for battery-operated Raspberry Pi Pico / Pico 2.

The library API and the power state model are documented in the
[main repository README](https://github.com/elehobica/pico_battery_op#readme). This file only covers
what is specific to the Arduino build.

This repository is **generated**: every file under `src/` is produced by
[`tools/vendor.sh`](tools/vendor.sh) from the upstream repository and from pico-extras / pico-sdk
(see [Vendoring](#vendoring)). Report issues and send pull requests against the
[main repository](https://github.com/elehobica/pico_battery_op) instead of editing `src/` here.

## Requirements

- **[arduino-pico](https://github.com/earlephilhower/arduino-pico) core with Pico SDK 2.3.0** (5.7.0
  or later; developed against 6.0.0). The vendored pico-extras sources (see below) are taken from
  pico-extras `sdk-2.3.0`, so the core's bundled SDK should match to avoid API drift.
- The **mandatory external power circuit** described in the main repository. Without it the power
  state machine cannot work.

## Installation

Use the Arduino Library Manager: `Sketch > Include Library > Manage Libraries...`, search for
**pico_battery_op** and install.

To install a specific revision manually instead, download this repository as a ZIP and use
`Sketch > Include Library > Add .ZIP Library...`, or unpack it into your sketchbook `libraries/`
folder.

Then open `File > Examples > pico_battery_op > battery_op_basic`.

## Vendoring

All sources under `src/` are committed here as real files - the Library Manager distributes the
repository as an archive, so submodules and build-time generation are not possible - but they are
**generated, not authored**:

| Generated file | Origin | Patch |
|---|---|---|
| `src/pico_battery_op.h` | [elehobica/pico_battery_op](https://github.com/elehobica/pico_battery_op) | none (verbatim) |
| `src/pico_battery_op.cpp` | [elehobica/pico_battery_op](https://github.com/elehobica/pico_battery_op) | none (verbatim) |
| `src/pbo_vendor/pbo_rosc.h` | pico-sdk `2.3.0` | none (verbatim) |
| `src/pbo_vendor/pbo_sleep.h` | pico-extras `sdk-2.3.0` | include / guard rewrite, `pbov_` prefix |
| `src/pbo_vendor/pbo_sleep.c` | pico-extras `sdk-2.3.0` | include rewrite, `pbov_` prefix, `ARDUINO` guard |

`tools/vendor.sh` performs the fetch and the patching, and asserts every assumption it makes about
the upstream text (see the self check in the script), so an upstream change that would break the
patching fails loudly instead of producing sources that do not compile or that collide at link time.
The exact revisions that produced the current `src/` are recorded in
[`src/pbo_vendor/VENDOR_INFO.txt`](src/pbo_vendor/VENDOR_INFO.txt).

The origins (repositories and the pico-extras / pico-sdk tags) are hardcoded in the script rather
than taken from workflow inputs, and the
[`vendor`](.github/workflows/vendor.yml) workflow is `workflow_dispatch` only.

```
$ ./tools/vendor.sh                 # refresh src/ from the upstream default branch
$ ./tools/vendor.sh --ref 1.2.0     # ... from a specific upstream tag
```

## Why these files are vendored

The Arduino core does not ship **pico-extras**, which provides the RP2 dormant implementation this
library depends on (`sleep_run_from_xosc()`, `sleep_goto_dormant_until_pin()`, `sleep_power_up()`).
Its sources are therefore vendored into `src/pbo_vendor/`. They keep their original copyright
headers and are BSD-3-Clause (Raspberry Pi (Trading) Ltd.), compatible with this project's
BSD-2-Clause.

**Why `pbo_rosc.h`.** `pbo_sleep.c` calls `rosc_disable()` / `rosc_set_dormant()` / `rosc_restart()`.
Their object code is in the core's `libpico.a` (`hardware_rosc` is built into it), but the Arduino
core does **not** put `hardware_rosc` on the compile include path, so `hardware/rosc.h` is not found.
`pbo_rosc.h` is a verbatim copy of that header supplying the declarations; the functions keep their
real names because they resolve to the single core implementation (they are not our code, so there is
nothing to duplicate). The unrelated `hardware_rosc_extra` from pico-extras is **not** vendored:
nothing in `pbo_sleep.*` uses it.

**No `pico_low_power`.** `pbo_dormant_set_low_leakage()` deliberately reimplements the GPIO sweep on
`hardware_gpio` instead of calling `pico_low_power`'s
`low_power_set_pins_low_leakage_exclude_mask()`. Referencing that function would pull the whole
`low_power.c.o` into the link, and on **RP2350** that object also contains the Pstate /
persistent-data code, which fails to link under the Arduino core (its RP2350 linker script omits
`__persistent_data_start__` / `__persistent_data_end__`). Avoiding the dependency fixes the Pico 2
build and works identically on RP2040.

**Namespacing.** Arduino links all libraries of a sketch together, so two libraries bundling the
same pico-extras sources would collide with `multiple definition` errors, and a shared
`pico/sleep.h` include path could resolve to the wrong copy. To prevent both, the vendored files
are kept under the unique `pbo_vendor/` folder (never on a shared include path) and **every global
function that `pbo_sleep.*` defines is prefixed with `pbov_`** (for example `sleep_power_up` ->
`pbov_sleep_power_up`), with the include guard renamed too. `pico_battery_op.cpp` maps the prefixed
names back to the SDK names locally, so this library can safely coexist with other RP2040 sleep /
dormant libraries. (The `rosc_*` declarations in `pbo_rosc.h` are intentionally *not* prefixed, as
noted above.)

Everything else these files need is already provided by the core and confirmed present on the
include path: `hardware_clocks`, `hardware_irq`, `hardware_gpio`, `hardware_xosc`, `hardware_pll`,
`hardware_sync`, `pico_runtime_init`, `pico_platform`, `pico_aon_timer`, `hardware_structs`,
`hardware_regs`, and `hardware_powman` (RP2350 only).

## Serial / USB behavior

Under the Arduino core the USB CDC stack is owned by the core, and `pico_stdio_usb` /
`pico_stdio_uart` are not linked. The library therefore skips its own stdio init/deinit when
`ARDUINO` is defined; use the core's `Serial` object as usual.

For the same reason, `setup_default_uart()` (called by the vendored `pbo_sleep.c` after clock
changes) is not linked either, so those two calls are guarded with `#if !defined(ARDUINO)`. This is
the only local patch to the vendored pico-extras code beyond the `pbov_` renaming.

Note that dormant mode stops the clocks, so the USB connection drops while the board is in Sleep or
Charging. After waking, the host normally re-enumerates the device, but the serial monitor may need
to be reopened.

## License

BSD-2-Clause (see [LICENSE](LICENSE)), except the vendored pico-extras / pico-sdk files under
`src/pbo_vendor/` noted above, which are BSD-3-Clause (Raspberry Pi (Trading) Ltd.) and carry their
original headers.
