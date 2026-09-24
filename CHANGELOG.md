# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Requires Rails 8.1** (`activesupport >= 8.1`, was `>= 8.0`). Every
  consumer app already runs 8.1; 8.0 was never exercised in CI.

## [0.5.0] - 2026-09-24

Adopts the provider-plugin API of standard_id 0.42.

### Upgrade

- **Requires `standard_id` 0.42** (`~> 0.42`, was `>= 0.29, < 1.0`). Bump both
  together.
- **Rename `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` to
  `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`** when convenient. Initializers
  from the 0.4.0 generator assign the old names explicitly and keep working
  unchanged; the old names are also read as a deprecated ENV fallback (see
  Deprecated). sidekick-web already uses the canonical names.
- **Expect a boot warning if the secret is missing.** With `google_client_id`
  set and `google_client_secret` blank, standard_id now logs a warning at boot
  (raises in production under `c.social.provider_misconfiguration = :raise`).
  An app that deliberately accepts only native ID tokens and has no secret
  should keep that setting at `:warn`.
- **Specs stubbing the tokeninfo call:** access-token verification now posts to
  `TOKEN_INFO_ENDPOINT` (`https://oauth2.googleapis.com/tokeninfo`), not
  `https://www.googleapis.com/oauth2/v3/tokeninfo`. ID-token stubs against
  `TOKEN_INFO_ENDPOINT` (sidekick-web's `social_callback_spec.rb`) are
  unaffected.
- **Anyone rescuing on message text:** several messages changed (see Changed).
  `StandardId::Google::Railtie` no longer exists.

### Added

- **Required config field.** `google_client_secret` is declared
  `required: true`, so `StandardId::Providers::Google.configuration_errors` and
  standard_id's boot check report it whenever `google_client_id` (the enabling
  field) is set.
- **ENV fallback** through standard_id 0.42: `GOOGLE_CLIENT_ID`,
  `GOOGLE_CLIENT_SECRET`.
- Specs for `resolve_params`, `skip_csrf?`, `supports_mobile_callback?` /
  `flow_for`, nonce handling (web code exchange included) and configuration,
  plus standard_id's `"a registered StandardId provider"` shared example.

### Changed

- **One tokeninfo endpoint.** ID tokens and access tokens are both verified
  against `TOKEN_INFO_ENDPOINT`, `https://oauth2.googleapis.com/tokeninfo` —
  the endpoint Google documents for both. Access tokens previously went to a
  hard-coded `https://www.googleapis.com/oauth2/v3/tokeninfo`.
- **The id_token and access_token flows no longer need `google_client_secret`.**
  Both verify through tokeninfo and compare the audience to the client ID; only
  the web code exchange sends the secret. Previously every flow raised
  `Google provider is not configured` without it.
- **Nonce mismatches no longer leak the nonce.** The message was
  `ID token nonce mismatch. Expected: <nonce>, got: <nonce>`; it is now
  standard_id's `ID token nonce mismatch`, and the comparison is constant-time.
  The nonce is now checked after the audience and issuer.
- **Audience and issuer errors no longer echo values** — the old messages
  included this app's client ID and the presented `aud`/`iss`. A token with no
  `aud` at all is rejected explicitly.
- **The duplicated helpers are gone** in favour of standard_id's
  `Providers::Base`: `rescue_to_oauth_error`, `verify_nonce!`,
  `build_authorization_url`, `extract_tokens` (the private
  `extract_token_payload` is removed). `lib/standard_id/google/railtie.rb` is
  replaced by `StandardId::Providers.plugin_railtie(:google, ...)`.
- **Error messages**, now consistently Google-prefixed:
  - `Either code, id_token, or access_token must be provided` → `Google sign-in requires a code, an id_token or an access_token`
  - `Google provider is not configured` → `Google OAuth is not configured` (client ID missing) or `Google OAuth credentials are incomplete: google_client_secret not set` (code exchange only)
  - `Missing authorization code` → `Google authorization code is missing`
  - `Failed to exchange Google authorization code` → `...: <error>` (Google's `error`, else `HTTP <status>`)
  - `Google response missing access token` → `Google token response is missing access_token`
  - `Missing id_token` → `Google id_token is missing`
  - `Invalid or expired id_token` → `Invalid Google ID token: invalid or expired`
  - `ID token audience mismatch. Expected: ..., got: ...` → `Invalid Google ID token audience`
  - `ID token issuer invalid. Expected Google, got: ...` → `Invalid Google ID token issuer`
  - `Missing access token` → `Google access token is missing`
  - `Invalid or expired access token` → `Invalid Google access token: invalid or expired`
  - `Access token audience mismatch. Expected: ..., got: ...` → `Invalid Google access token audience`
  - `Failed to fetch Google user info` → `...: HTTP <status>`
- **Spec layout mirrors `lib/`** and standard_id-apple:
  `spec/standard_id/providers/google_spec.rb` →
  `spec/standard_id/google/providers/google_spec.rb`, plus
  `spec/standard_id/google/registration_spec.rb`.
- Install generator and README use the canonical `GOOGLE_CLIENT_ID` /
  `GOOGLE_CLIENT_SECRET`, and document the ENV fallback, required field and
  flows.

### Deprecated

- **`GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`** as ENV sources.
  Read only when the field is never assigned and the canonical variable is
  unset, with one warning per variable per process through
  `StandardId.deprecator`.

### Removed

- `StandardId::Google::Railtie` (replaced by the Railtie `plugin_railtie`
  defines, `StandardId::Providers::Railties::Google`).

## [0.4.0] - 2026-07-31

### Added

- **Install generator: `bin/rails g standard_id:google:install`.** Writes
  `config/initializers/standard_id_google.rb` with the `social.google_*` fields
  wired to ENV, then prints the environment variables the host has to set and
  the reminder that `/auth/callback/google` must be registered as an authorized
  redirect URI for **every** origin served — the Google console matches the
  redirect exactly, so staging and production each need their own. Idempotent:
  re-running skips an existing initializer; `--force` overwrites,
  `--skip-initializer` writes nothing.

  It writes a **separate** file rather than editing `standard_id.rb`, so the
  provider can be removed by deleting one file and `standard_id`'s own install
  generator stays free to overwrite its initializer without clobbering these
  credentials. Initializers load alphabetically, so the base config is applied
  first. The generated file uses the `config.social.` form throughout — a spec
  pins that it never emits the unqualified `config.google_*` form, which works
  today only because the names happen to be unique across scopes.

  Five of the nine `standard_*` gems shipped an install generator and this was
  not one of them, which left both consumers assembling the block from the
  README by hand.

### Documentation

- **Consumer list corrected in `CLAUDE.md`: this gem has two consumers, not
  one.** It named `luminality-web` only; `sidekick-web` also consumes it. Both
  live in sibling workspaces rather than beside this repo, which is how the
  second one went unnoticed.

- **Corrected the Configuration section, which showed a form that raised on
  `standard_id` <= 0.32.0.** These fields are declared by this gem, and until
  `standard_id` 0.33.0 they were declared from this gem's Railtie
  `after_initialize` — after `config/initializers` — so the documented plain
  initializer raised `StandardId::ConfigurationError: Unknown field
  'google_client_id' for scope 'social'`. The README now records the
  `after_initialize` workaround for older `standard_id`, states that 0.33.0
  declares provider fields before `:load_config_initializers` so the plain form
  is correct there, and notes that the fields do not exist at all without this
  gem in the Gemfile — on any `standard_id` version.

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
