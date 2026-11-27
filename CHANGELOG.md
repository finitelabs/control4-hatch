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

## v20261127 - 2026-11-27

### Added

- Added Control4 load groups to the Hatch Night Light and Hatch Volume. Each
  joins a load group and follows the group's level, ramps and sync.

### Fixed

- Fixed the Hatch Night Light sometimes going to its old brightness when its
  color is changed right after its level.
- Fixed the Hatch Night Light sometimes coming on in its old color, instead of
  one set while it was turning off.

### Changed

- Changed the Hatch Night Light and Hatch Volume to show offline and keep their
  level and keypad button LEDs while the account has lost its connection to
  Hatch, or a device is offline, where they used to show off.
- Changed the Hatch Night Light and Hatch Volume to show a change in Control4 as
  soon as it is sent, and put it right within 5 seconds if Hatch does not take
  it.
- Changed the Hatch Volume to keep playing when it is turned On while it plays a
  sound, where it used to start the chosen favorite again.
- Changed the Hatch Night Light and Hatch Volume to report their brightness, and
  the Night Light its color, to Control4 as they find them after a driver
  restart or a reconnect, even when they have not changed.
- Changed the Hatch Night Light and Hatch Volume to no longer fire a change
  event in Control4 programming for a command setting the brightness or color
  they already show.
- Changed the Hatch Night Light and Hatch Volume to answer brightness queries
  with the level they last reported, also during a fade or while the device
  can't be reached.
- Changed the Hatch Night Light or Hatch Volume to show offline after it is
  bound to a different device, until the new device reports.

## v20261111 - 2026-11-11

<!-- #ifdef DRIVERCENTRAL -->

### Added

- Added a Support Code property to every Hatch driver, which lets Finite Labs
  support open the driver's Lua tab and its Trace and Ultra log levels for an
  hour.
- Added Cloud Monitoring, Enabled by default, which sends Finite Labs each
  driver's memory use every hour and each error it hits, and a Diagnostics
  Snapshot action.

<!-- #endif -->

### Fixed

- Fixed the Hatch drivers sometimes showing a light or sound as off, or at the
  wrong level, while the device was on.
- Fixed a color set while the Hatch Night Light was off turning the light on,
  and its next turn-on now comes on in that color.
- Fixed the Hatch Sound Machine sometimes turning itself off, or leaving a
  now-playing card that could not be controlled, after a driver update or
  account reconnect while it was playing.
- Fixed the Hatch companion drivers sometimes showing the account as connected
  after it lost its connection to Hatch.
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed an automatic update sometimes leaving the companion drivers on the
  previous version, where they could stop responding until the next update.
  <!-- #endif -->

### Changed

- Changed the Hatch Night Light and Hatch Volume to show off while the
  connection to Hatch is lost, and their state again once it reconnects.
  <!-- #ifdef DRIVERCENTRAL -->
- Changed Automatic Updates to one setting for every Hatch driver in the
  project, so the drivers update together.
  <!-- #endif -->

### Removed

- Removed the scene, on mode, Default On and ramp options from the Hatch Night
  Light and Hatch Volume, since neither driver acted on them.

## v20260816 - 2026-08-16

### Added

- Added the Hatch Volume driver, which presents a device's volume as a dimmer
  for integrations that only control lights.
- Added a Turn On Plays property to Hatch Volume, which picks the sound or
  favorite that turning it on plays.
- Added Started Playing and Stopped Playing events to the Hatch Sound Machine,
  which also fire for playback started from the Hatch app or the device itself.
- Added Programming conditionals to the Hatch Sound Machine for whether it is
  playing, and for which sound or favorite is playing.
- Added automatic refresh of sounds and favorites when they change in the Hatch
  app, with no driver reload.
- Added normal room source behavior to the Hatch Sound Machine, so starting it
  takes the room and selecting another source stops it.

### Fixed

- Fixed a reconnect or credential change on the account driver briefly reporting
  its companion drivers as disconnected, and a deliberate stop being reported as
  a disconnect.
- Fixed the Hatch Night Light never reporting itself online, which could leave
  it grayed out and unusable in Navigator.
- Fixed stopping the sound machine turning off the whole room, which ended a
  video session in rooms with a TV.
- Fixed a second room off being sent behind the one you pressed, which could
  switch a TV with a power toggle back on.
- Fixed starting the sound machine from the device itself taking a room the TV
  was holding, which switched a TV with a power toggle back on. It now takes a
  room only when you start it from Control4.
- Fixed Hatch Volume listing favorites that share a name as identical entries,
  where choosing either one started the first. Repeats now carry their touch
  ring number, matching the Hatch app.
- Fixed the sound machine reporting its volume continuously rather than only
  when it changed, which made Programming watching the volume run constantly.
- Fixed the companion drivers showing their last known state as live, and
  reporting themselves reachable, while the account driver had no cloud
  connection or had not yet found the device.

## v20260806 - 2026-08-06

### Added

- Added the **Hatch** account driver, which signs in to the Hatch cloud, finds
  the devices on the account and shares one connection among them, reconnecting
  on its own after a network drop or controller restart.
- Added the **Hatch Sound Machine** companion, which plays a device's sounds and
  favorites as a Control4 media source in its room with no amplifier needed,
  with now playing, cover art, volume and mute.
- Added the **Hatch Night Light** companion, which presents a device's night
  light as a standard Control4 light with on and off, brightness, full color and
  Advanced Lighting Scenes.
- Added Play Sound, Play Favorite and Stop programming commands, with sound and
  favorite lists populated from the device's own catalog.
- Added cover art on the now-playing card and in the browse lists, for sounds
  and favorites.
- Added support for Rest+ and Restore, including Restore's own sounds.
