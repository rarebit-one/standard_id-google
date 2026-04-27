# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- CI and release workflows migrated to the shared `rarebit-one/.github` reusable workflows (`reusable-gem-ci.yml@v1`, `reusable-gem-release.yml@v1`); `.github/workflows/ci.yml` and `release.yml` are now thin shims.

## [0.2.0] - 2026-04-21

### Added

- Auto-register provider with StandardId via `Rails::Railtie` on `config.after_initialize`, so apps that bundle the gem no longer need an explicit initializer (#27)

## [0.1.2] - 2026-01-13

### Added

- Support nonce and passing custom parameters to Google Sign In (#1)

## [0.1.1] - 2025-12-24

### Fixed

- Thread safety improvements

## [0.1.0] - 2025-12-20

### Added

- Initial release of Google Sign In provider plugin for StandardId
