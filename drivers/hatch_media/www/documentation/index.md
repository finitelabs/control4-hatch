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

<img alt="Hatch" src="./images/header.png" width="500"/>

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

# <span style="color:#13294C">Setup</span>

1. Add the Hatch account driver and enter your account credentials. Wait for its
   Connection Status to report the discovered devices.
1. Add this driver to the room that has the Hatch device.
1. In Connections, bind this driver's **Hatch Device** connection to the
   matching **Sound Machine** connection on the Hatch account driver.
1. Bind this driver's **Audio End-Point** to the room's audio end point so the
   room can listen to it.

# <span style="color:#13294C">Programming</span>

The driver adds these commands for use in Composer programming:

- **Play Sound**: start one of the device's sounds, chosen from a list.
- **Play Favorite**: start one of the device's favorites (Hatch routines),
  chosen from a list.
- **Stop**: stop playback on the device.

Volume, mute, and transport are also available through the standard room audio
and media session controls.

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

<!-- #endif -->
