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

The Hatch Night Light driver presents one Hatch device's RGB night light as a
standard Control4 light (light_v2). Turn the light on and off, set brightness,
and pick a color from the light UI or from Composer programming, and use it in
Advanced Lighting Scenes like any other light.

This is a companion to the Hatch account driver, which owns the cloud
connection. This driver holds no credentials of its own: it binds to the account
driver, receives the light's on/off, brightness, and color state over that
binding, and sends changes back through it. Color is translated with Control4's
built-in color model, so the Hatch light behaves like the rest of the lighting
in a project.

# <span style="color:#13294C">Setup</span>

1. Add the Hatch account driver and enter your account credentials. Wait for its
   Connection Status to report the discovered devices.
1. Add this driver to the room that has the Hatch device.
1. In Connections, bind this driver's **Hatch Device** connection to the
   matching **Night Light** connection on the Hatch account driver.

# <span style="color:#13294C">Programming</span>

The light is a standard Control4 light, so it works with the built-in light
programming commands and events (on, off, toggle, set level, set color) and with
Advanced Lighting Scenes. No driver-specific commands are required.

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
