# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`standard_id` dependency tightened from `~> 0.1, >= 0.1.7` to `~> 0.29.0`.**
  The old constraint claimed compatibility with every `0.x` release while this
  plugin reaches into `StandardId::ProviderRegistry` and
  `StandardId::Providers::Google`, and `standard_id` is pre-1.0 with breaking
  minors. Bundler would happily resolve against an untested minor and fail at
  runtime instead of at resolution. Both current consumers already pin
  `standard_id "~> 0.29.0"`, so nothing existing is affected.

### Fixed

- Gemspec no longer packages the `.claude/` directory. Published `0.3.0` shipped
  `.claude/settings.json`, `.claude/hooks/enforce-worktree.sh`, and three skill
  files to every consumer — this gem's `spec.files` reject-list was the only one
  in the `standard_*` family missing the `.claude/` prefix (`standard_id-apple`
  already had it). Packaged file count drops 21 → 16; `lib/` and `LICENSE` are
  unaffected.
- Gemspec now uses an allow-list (`Dir["lib/**/*", …]`) rather than a
  `git ls-files` reject-list, so packaging fails **closed** and this class of
  leak cannot recur. Also drops `.editorconfig`, `.pinact.yaml`, `.rspec`,
  `.rubocop.yml`, `.ruby-version`, `AGENTS.md`, `CLAUDE.md`, and
  `CODE_OF_CONDUCT.md`; `lib/` is byte-identical.

## [0.3.0] - 2026-04-29

### Added

- `.editorconfig` and `AGENTS.md` for dev tooling parity with the parent `standard_id` gem.
- SimpleCov branch coverage reporting in `spec/spec_helper.rb`. No minimum threshold is enforced; `coverage/` is gitignored.

### Changed

- CI and release workflows migrated to the shared `rarebit-one/.github` reusable workflows (`reusable-gem-ci.yml@v1`, `reusable-gem-release.yml@v1`); `.github/workflows/ci.yml` and `release.yml` are now thin shims.
- CI matrix expanded to all four Ruby 4.0.x patch releases (`4.0.0`, `4.0.1`, `4.0.2`, `4.0.3`) and lint pinned to `4.0.3`. Branch protection will be updated post-merge to require the consolidated `ci / test` aggregator (added in `rarebit-one/.github#6`) instead of per-version checks, so future Ruby version churn won't require updating protection.

### Removed

- **BREAKING:** Dropped support for Ruby < 4.0. `required_ruby_version` is now `>= 4.0`. Aligns with `standard_id` (the parent gem) which made the same break in [rarebit-one/standard_id#195](https://github.com/rarebit-one/standard_id/pull/195) — host apps must upgrade to Ruby 4.0+ before bundling this version.

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
