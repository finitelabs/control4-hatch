<img alt="Hatch" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#13294C">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Hatch.

This suite brings Hatch sleep devices into Control4. It controls the sound
machine and RGB night light on Hatch Rest+ and Restore devices through the Hatch
cloud, with no separate bridge or Home Assistant instance required.

The suite is split into an account driver and per-function companion drivers.
The account driver owns a single cloud connection for the whole account (Hatch
login, then AWS IoT over an MQTT-over-WebSocket link to the device shadows),
discovers the devices on the account, and exposes a connection for each device
function. The companion drivers present those functions to Control4: the sound
machine as a media service with a room audio endpoint, and the night light as a
standard light. This keeps one connection per account no matter how many devices
or rooms are involved.

# <span style="color:#13294C">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Included Drivers](#included-drivers)
  - [Hatch](#hatch)
  - [Hatch Sound Machine](#hatch-sound-machine)
  - [Hatch Night Light](#hatch-night-light)
- [Installation](#installation)
  - [Installing the Drivers](#installing-the-drivers)
- [Support](#support)
- [Changelog](#changelog)

</div>

<div style="page-break-after: always"></div>

# <span style="color:#13294C">System Requirements</span>

- Control4 OS 3.3+
- A Hatch account (the email and password used in the Hatch mobile app)
- One or more supported Hatch devices already set up in the Hatch app: Rest+
  (Rest+ 2nd gen / riot) and Restore

# <span style="color:#13294C">Included Drivers</span>

## Hatch

The account driver, and the driver to add first. Enter your Hatch account email
and password and it connects to the Hatch cloud, discovers the devices on the
account, and creates a connection for each device function. The sound machine
and night light drivers bind to those connections, so the account driver is the
only place credentials are entered and the only cloud connection that is opened.

**Key features:**

- One cloud connection for the whole account, shared by every device and room
- Automatic discovery of the devices on the account
- Live device state (playback, volume, light color and brightness) kept in sync
  from the Hatch device shadows
- Reconnects on its own after a network drop or controller restart

## Hatch Sound Machine

Presents one device's sound machine as a Control4 media service with its own
room audio endpoint, so it behaves like any other listening source.

**Key features:**

- Browse and play the device's sounds and favorites from the room
- Now-playing, stop, and volume in the standard Control4 listening session
- Play Sound, Play Favorite, and Stop programming commands
- Adds itself as a room audio endpoint, so no external amplifier is needed

## Hatch Night Light

Presents one device's RGB night light as a standard Control4 light (light_v2).

**Key features:**

- On, off, brightness, and full color from the light UI and from programming
- Color handled with Control4's built-in color model, so it matches the rest of
  the lighting in a project
- Advanced Lighting Scenes support

<div style="page-break-after: always"></div>

# <span style="color:#13294C">Installation</span>

## Installing the Drivers

1. Download the latest `control4-hatch.zip` from
   [Github](https://github.com/finitelabs/control4-hatch/releases/latest).
1. Extract and install the desired `.c4z` driver files.
1. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

Add the Hatch account driver first and enter your account credentials, then add
a Hatch Sound Machine and/or Hatch Night Light to the room with the device and
bind it to the matching connection on the account driver.

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

<div style="page-break-after: always"></div>

# <span style="color:#13294C">Support</span>

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-hatch/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<div style="page-break-after: always"></div>

# <span style="color:#13294C">Changelog</span>

<!-- prettier-ignore-start -->

<!-- prettier-ignore-end -->

## Unreleased
