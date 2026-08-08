<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="Hatch Sound Machine" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#13294C">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Hatch.

<!-- #endif -->

The Hatch Sound Machine driver presents one Hatch device's sound machine as a
Control4 media service with its own room audio endpoint. Browse and play the
device's sounds and favorites, stop playback, and control volume from the room,
the same way you would any other listening source.

This is a companion to the Hatch account driver, which owns the cloud
connection. This driver holds no credentials of its own: it binds to the account
driver, receives the device's sound catalog and playback state over that
binding, and sends play, stop, and volume actions back through it. Because the
device plays its own audio, the driver also adds itself as a room audio
endpoint, so no external amplifier or matrix is required.

# <span style="color:#13294C">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
  - [Connections](#connections)
- [Programming](#programming)
  - [Commands](#commands)
  - [Events](#events)
  - [Conditionals](#conditionals)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#13294C">System Requirements</span>

- Control4 OS 3.3+
- The Hatch account driver, configured and connected, with a Hatch device that
  has a sound machine

# <span style="color:#13294C">Features</span>

- Control4 media service with its own room audio endpoint, so no external
  amplifier or matrix is required
- Browse and play the device's sounds and favorites (Hatch routines) from the
  room
- Now-playing, stop, and volume in the standard Control4 listening session
- Play Sound, Play Favorite, and Stop programming commands
- Real-time playback and volume synchronization with the Hatch device through
  the account driver

# <span style="color:#13294C">Compatibility</span>

The sound machine is supported on Hatch devices with an audio player, which
covers Rest+ (Rest+ 2nd gen / riot) and Restore. The account driver detects each
device and exposes a Sound Machine connection for it. The available sounds and
favorites come from the device's own catalog.

# <span style="color:#13294C">Installer Setup</span>

Refer to the main Hatch driver documentation for account setup. Once the account
driver is configured and connected to your Hatch devices, bind the Hatch Sound
Machine driver to the Sound Machine connection exposed by the account driver and
add it to the room's audio.

## Adding the Driver

1. Add the Hatch account driver and enter your account credentials. Wait for its
   Connection Status to report the discovered devices.
1. Add the Hatch Sound Machine driver to the room that has the Hatch device.
1. In Connections, bind this driver's `Hatch Device` connection to the matching
   `Sound Machine` connection on the Hatch account driver.
1. Bind this driver's `Audio End-Point` connection to the room's audio end point
   so the room can listen to it.

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral. Default is `On`.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

## Connections

### Hatch Sound Machine (provider)

The Control4 media service and room audio endpoint. This is automatically
managed by the driver and provides the listening source to the room.

### Audio End-Point (provider)

Bind this connection to the room's audio end point so the room can select and
play the Hatch device.

### Hatch Device (consumer)

Bind this connection to the Sound Machine connection exposed by the main Hatch
account driver.

# <span style="color:#13294C">Programming</span>

## Commands

The driver adds these commands for use in Composer programming:

| Command           | Description                                                               |
| ----------------- | ------------------------------------------------------------------------- |
| **Play Sound**    | Start one of the device's sounds, chosen from a list.                     |
| **Play Favorite** | Start one of the device's favorites (Hatch routines), chosen from a list. |
| **Stop**          | Stop playback on the device.                                              |

> **Note:** The Sound and Favorite lists are populated from the device's own
> catalog once the account driver has connected and discovered the device.

Volume, mute, and transport are also available through the standard room audio
and media session controls, so they do not need dedicated programming commands.

## Events

The driver fires these events for use in Composer programming:

| Event               | Description                 |
| ------------------- | --------------------------- |
| **Started Playing** | The device started playing. |
| **Stopped Playing** | The device stopped playing. |

> **Note:** Both fire whatever started or stopped playback, including the Hatch
> app and the device itself, not only Control4.

## Conditionals

The driver adds these conditionals for use in Composer programming:

| Conditional          | Description                                   |
| -------------------- | --------------------------------------------- |
| **Playback state**   | Whether the device is playing.                |
| **Current sound**    | The sound playing now, chosen from a list.    |
| **Current favorite** | The favorite playing now, chosen from a list. |

> **Note:** An idle device matches nothing, so it fails an "is" test and passes
> an "is not" test.

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#13294C">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC.

<!-- #endif -->

# <span style="color:#13294C">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4 or
your Hatch devices, you can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-hatch/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->
