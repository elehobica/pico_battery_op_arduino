# pico_battery_op (Arduino library)

Arduino port of the [pico_battery_op](https://github.com/elehobica/pico_battery_op) power-management
library for battery-operated Raspberry Pi Pico / Pico 2.

The library API and the power state model are documented in the
[main repository README](https://github.com/elehobica/pico_battery_op#readme). This file only covers
what is specific to the Arduino build.

This repository is **generated**: every file under `src/` is produced by
[`tools/vendor.sh`](tools/vendor.sh) from the upstream repository and from pico-extras / pico-sdk
(see [docs/VENDORING.md](docs/VENDORING.md)). Report issues and send pull requests against the
[main repository](https://github.com/elehobica/pico_battery_op) instead of editing `src/` here.

## Requirements

- **Raspberry Pi Pico (RP2040) or Pico 2 (RP2350)**. Pico W / Pico 2 W are **not supported**: GP23,
  GP24 and GP29, which this library uses for the DC/DC PSM control, the USB-power detection and the
  battery ADC, are taken by the CYW43 wireless chip on those boards. The arduino-pico core exposes
  every board under the single `rp2040` architecture, so nothing stops the IDE from offering this
  library on a W board - the incompatibility is in the wiring, not in the build.
- **[arduino-pico](https://github.com/earlephilhower/arduino-pico) core with Pico SDK 2.3.0** (5.7.0
  or later; developed against 6.0.0). The vendored pico-extras sources are taken from
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

## Usage

The API is the same as in the main repository; only the surrounding structure follows Arduino's
`setup()` / `loop()` convention.

```cpp
#include "pico_battery_op.h"

void setup()
{
    pbo_init(nullptr);   // nullptr -> all defaults
    pbo_start();
}

void loop()
{
    pbo_process();       // runs the power state machine (may block while dormant)
    delay(50);
}
```

`pbo_process()` must be called periodically from `loop()`. It uses absolute time internally, so the
exact cadence is not critical, but it is what runs the power state machine and the button gesture
recognition, and it blocks while the board is dormant (a Sleep, or Charging).

Pass a `pbo_config_t` to `pbo_init()` to override the pin assignments, the deferred-action delays,
the POWER-gesture mapping or the application callbacks:

```cpp
pbo_config_t config = pbo_get_default_config();
config.pin_user_sw = 17;                              // override only what your board needs
config.callbacks.on_enter_dormant = on_enter_dormant; // quiesce your peripherals before dormant
pbo_init(&config);
pbo_start();
```

See [examples/battery_op_basic](examples/battery_op_basic/battery_op_basic.ino) for a complete
sketch, and the [main repository README](https://github.com/elehobica/pico_battery_op#api) for the
full API and the power state model.

## Coexisting with other sleep / dormant libraries

The pico-extras sleep sources this library needs are vendored under `src/pbo_vendor/`, and every
global function they define is prefixed with `pbov_`. A sketch can therefore use this library
together with another RP2040 sleep / dormant library that bundles the same pico-extras code, without
`multiple definition` errors. See [docs/VENDORING.md](docs/VENDORING.md) for the details.

## Serial / USB behavior

Under the Arduino core the USB CDC stack is owned by the core, and `pico_stdio_usb` /
`pico_stdio_uart` are not linked. The library therefore skips its own stdio init/deinit when
`ARDUINO` is defined; use the core's `Serial` object as usual.

For the same reason, `setup_default_uart()` (called by the vendored `pbo_sleep.c` after clock
changes) is not linked either, so those two calls are guarded with `#if !defined(ARDUINO)`.

Note that dormant mode stops the clocks, so the USB connection drops while the board is in Sleep or
Charging. After waking, the host normally re-enumerates the device, but the serial monitor may need
to be reopened.

## License

BSD-2-Clause (see [LICENSE](LICENSE)), except the vendored pico-extras / pico-sdk files under
`src/pbo_vendor/` (see [docs/VENDORING.md](docs/VENDORING.md)), which are BSD-3-Clause
(Raspberry Pi (Trading) Ltd.) and carry their original headers.
