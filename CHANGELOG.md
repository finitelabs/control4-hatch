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

### Fixed

- Restore persisted dynamic bindings from `OnDriverInit` instead of
  `OnDriverLateInit`. Director resolves stored connections before
  `OnDriverLateInit` runs, so connections where this driver holds the consumer
  side were permanently dropped across a Director restart

### Removed

- Removed the orphaned `package-lock.json` left over from the retired
  electron-pdf docs pipeline; node/npm is not part of the build
