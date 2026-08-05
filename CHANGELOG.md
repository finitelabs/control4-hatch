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

### Changed

- Dynamic bindings are now restored earlier in driver startup, before Director
  resolves stored connections

### Removed

- Removed the orphaned `package-lock.json` left over from the retired
  electron-pdf docs pipeline; node/npm is not part of the build
