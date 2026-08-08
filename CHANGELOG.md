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

### Added

- Added the Hatch Volume driver, presenting a device's volume as a dimmer for
  integrations that only understand lights, such as Apple Home.
- Added a Turn On Plays property to Hatch Volume, choosing what turning it on
  starts. A favorite starts at its own volume, a sound at the Default On level.
- Added Started Playing and Stopped Playing events to the Hatch Sound Machine,
  which also fire for playback started from the Hatch app or the device itself.
- Added Programming conditionals to the Hatch Sound Machine for whether it is
  playing, and for which sound or favorite is playing.
- Sounds and favorites now refresh on their own when they change in the Hatch
  app, with no driver reload.
- The Hatch Sound Machine now behaves as a normal room source: starting it takes
  the room, and selecting another source stops it.

### Fixed

- Fixed the Hatch Night Light never reporting itself online, which could leave
  it greyed out and unusable in Navigator.
- Fixed stopping the sound machine turning off the whole room, which ended a
  video session in rooms with a TV.
- Fixed a second room off being sent behind the one you pressed, which could
  switch a TV with a power toggle back on.
- Fixed Hatch Volume listing favorites that share a name as identical entries,
  where choosing either one started the first. Repeats now carry their touch
  ring number, matching the Hatch app.
- Fixed the sound machine reporting its volume continuously rather than only
  when it changed, which made Programming watching the volume run constantly.
- Fixed the companion drivers showing their last known state as though it were
  live after the account driver lost its cloud connection.

## v20260806 - 2026-08-06

### Added

- **Hatch** account driver. Signs in to the Hatch cloud, discovers the devices
  on the account, and holds a single AWS IoT connection (MQTT over WebSocket to
  the device shadows) shared by every device and room. Reconnects on its own
  after a network drop or controller restart, reusing the member token.
- **Hatch Sound Machine** companion. Presents a device's sound machine as a
  Control4 media service with its own room audio endpoint, so no external
  amplifier is needed. Browse and play sounds and favorites, now-playing with
  cover art, volume and mute in the standard listening session.
- **Hatch Night Light** companion. Presents a device's RGB night light as a
  standard Control4 light, with on/off, brightness, full color and Advanced
  Lighting Scenes support.
- Play Sound, Play Favorite and Stop programming commands, with sound and
  favorite lists populated from the device's own catalog.
- Cover art on both the now-playing card and the browse lists, resolved per
  sound and shared with favorites through the sound their routine plays.
- Support for Rest+ (riot, riotPlus) and Restore (restoreV5). Restore sound
  content is read from Hatch's Contentful CMS, which the REST content endpoint
  does not serve.
