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

- [Installer Setup](#installer-setup)

  - [Installing the Drivers](#installing-the-drivers)
  - [Driver Setup](#driver-setup)
    - [Driver Properties](#driver-properties)
    - [Driver Actions](#driver-actions)

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

# <span style="color:#13294C">Installer Setup</span>

## Installing the Drivers

1. Download the latest `control4-hatch.zip` from
   [Github](https://github.com/finitelabs/control4-hatch/releases/latest).
1. Extract and install the desired `.c4z` driver files.
1. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

## Driver Setup

Add the Hatch account driver first and enter your account credentials, then add
a Hatch Sound Machine and/or Hatch Night Light to the room with the device and
bind it to the matching connection on the account driver.

1. Add the **Hatch** account driver to your project.
1. Enter your Hatch account **Email** and **Password**. The driver connects to
   the Hatch cloud and populates **Connection Status** and the discovered
   **Devices**.
1. Add a **Hatch Sound Machine** and/or **Hatch Night Light** to the room with
   the device, and bind its `Hatch Device` connection to the matching device
   connection exposed by the account driver.

Each companion driver includes its own documentation accessible from within
Composer Pro. Refer to the individual driver documentation for its property,
connection, and programming reference.

### Driver Properties

#### Cloud Settings

##### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates. Default is `On`.

##### Update Channel \[ **_Production_** | Prerelease \]

Selects which release channel automatic updates pull from. Default is
`Production`.

#### Account Settings

##### Email

Email address for your Hatch account (the one used in the Hatch mobile app).

##### Password

Password for your Hatch account.

##### Connection Status (read-only)

Displays the current status of the connection to the Hatch cloud.

##### Devices (read-only)

Lists the Hatch devices discovered on the account. Bind the companion drivers
(Hatch Sound Machine, Hatch Night Light) to these device connections.

#### Driver Settings

##### Driver Status (read-only)

Displays the current status of the driver.

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

##### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

### Driver Actions

#### Update Drivers

Checks for and installs the latest driver versions from the configured Update
Channel.

#### Reconnect

Drops and re-establishes the connection to the Hatch cloud.

#### Reset Driver

Clears the driver's stored state and reconnects.

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#13294C">Support</span>

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-hatch/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<div style="page-break-after: always"></div>

# <span style="color:#13294C">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased
