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

<img alt="Hatch Volume" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#13294C">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Hatch.

<!-- #endif -->

The Hatch Volume driver presents one Hatch device's sound machine volume as a
standard Control4 light (light_v2). Brightness is the volume percentage, and the
load being on means the sound machine is playing.

**You do not need this driver for Control4 itself.** The Hatch Sound Machine
driver already exposes volume natively through its media proxy, with a real
volume control in Navigator and in Composer programming. This driver exists for
integrations that only understand lights.

The case it solves is Apple Home. HomeKit has no concept of a media service, so
a Hatch bridged into Apple Home has no way to present its volume. A dimmer is
something HomeKit does understand, so exposing volume as one puts it in front of
Siri and the Home app, where it can be set directly or from a scene or
automation. The same reasoning applies to any other integration that speaks
lights but not media.

This is a companion to the Hatch account driver, which owns the cloud
connection. This driver holds no credentials of its own: it binds to the account
driver, receives volume and playback state over that binding, and sends changes
back through it. Because the account driver owns both sides of the exchange, it
knows which side a change came from and does not echo its own writes back, so
the volume and the dimmer stay in step without fighting each other.

# <span style="color:#13294C">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Behavior](#behavior)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
  - [Connections](#connections)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#13294C">System Requirements</span>

- Control4 OS 3.3+
- The Hatch account driver, configured and connected
- A HomeKit bridge, if the goal is exposing Hatch volume to Apple Home

# <span style="color:#13294C">Features</span>

- Control4 Light Proxy (light_v2) integration, so anything that understands a
  dimmer can control Hatch volume
- Brightness maps directly to volume percentage
- On resumes the last sound at the current volume; off stops playback
- Volume can be staged while stopped, since the Hatch accepts a volume change
  without starting playback
- Real-time two-way synchronization with the Hatch device through the account
  driver, with no Control4 programming required

# <span style="color:#13294C">Compatibility</span>

Every Hatch device has a sound machine, so the account driver exposes a Volume
connection for each device it discovers, covering Rest+ (Rest+ 2nd gen / riot)
and Restore.

# <span style="color:#13294C">Installer Setup</span>

Refer to the main Hatch driver documentation for account setup. Once the account
driver is configured and connected to your Hatch devices, bind the Hatch Volume
driver to the Volume connection exposed by the account driver.

## Adding the Driver

1. Add the Hatch account driver and enter your account credentials. Wait for its
   Connection Status to report the discovered devices.
1. Add the Hatch Volume driver to the room that has the Hatch device.
1. In Connections, bind this driver's `Hatch Device` connection to the matching
   `Volume` connection on the Hatch account driver.
1. The driver will synchronize its state once bound.

No programming is required. Add one driver per Hatch device you want to control
this way.

## Behavior

| Action                          | Result                                                    |
| ------------------------------- | --------------------------------------------------------- |
| Turn on, favorite selected      | Plays the favorite at the favorite's own volume           |
| Turn on, sound selected         | Plays the sound at the dimmer's Default On (preset) level |
| Turn off                        | Stops playback; the volume is left where it was           |
| Change brightness while playing | Sets the volume                                           |
| Change brightness while stopped | Treated as turning on, so the selection starts            |
| Sound machine starts            | The load turns on at the device's volume                  |
| Sound machine stops             | The load turns off                                        |
| Volume changed on the Hatch     | Brightness follows                                        |

`Turn On Plays` defaults to the first favorite, since a favorite is the only
self-contained answer to what turning the dimmer on should start: it carries its
own sound, volume and colour.

A favorite's volume is never overridden. The driver reads the level the routine
will apply and reports it as the dimmer's brightness, so the slider matches what
the Hatch is actually doing. A sound has no volume of its own, so it starts at
the dimmer's Default On level, sent in the same update as the sound so it cannot
start at the previous level and jump.

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

### Light (provider)

The Control4 Light proxy connection. This is automatically managed by the driver
and provides the dimmer that represents volume.

### Hatch Device (consumer)

Bind this connection to the Volume connection exposed by the main Hatch account
driver.

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
