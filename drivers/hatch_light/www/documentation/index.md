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

<img alt="Hatch Night Light" src="./images/header.png" width="500"/>

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
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

<div style="page-break-after: always"></div>

# <span style="color:#13294C">System Requirements</span>

- Control4 OS 3.3+
- The Hatch account driver, configured and connected, with a Hatch device that
  has a night light

# <span style="color:#13294C">Features</span>

- Control4 Light Proxy (light_v2) integration for native Control4 lighting
  control
- On, off, brightness, and full RGB color from the light UI and from Composer
  programming
- Color handled with Control4's built-in color model, so it matches the rest of
  the lighting in a project
- Advanced Lighting Scenes participation
- Real-time state synchronization with the Hatch device through the account
  driver

# <span style="color:#13294C">Compatibility</span>

The night light is RGB. It is supported on Hatch devices that include a light,
which covers Rest+ (Rest+ 2nd gen / riot) and Restore. The account driver
detects each device and exposes a Night Light connection for it.

<div style="page-break-after: always"></div>

# <span style="color:#13294C">Installer Setup</span>

Refer to the main Hatch driver documentation for account setup. Once the account
driver is configured and connected to your Hatch devices, bind the Hatch Night
Light driver to the Night Light connection exposed by the account driver.

## Adding the Driver

1. Add the Hatch account driver and enter your account credentials. Wait for its
   Connection Status to report the discovered devices.
1. Add the Hatch Night Light driver to the room that has the Hatch device.
1. In Connections, bind this driver's `Hatch Device` connection to the matching
   `Night Light` connection on the Hatch account driver.
1. The driver will synchronize its state once bound.

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
and provides the light functionality to Control4.

### Hatch Device (consumer)

Bind this connection to the Night Light connection exposed by the main Hatch
account driver.

<div style="page-break-after: always"></div>

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

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
