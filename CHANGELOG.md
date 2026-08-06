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

## v20260806 - 2026-08-06

Initial release.

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
