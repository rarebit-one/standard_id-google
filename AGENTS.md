# AGENTS.md - AI Agent Guide for standard_id-google

`standard_id-google` is a provider plugin for the [StandardId](https://github.com/rarebit-one/standard_id) authentication engine. It packages a `StandardId::Providers::Google` implementation for Sign in with Google, and auto-registers itself with the host StandardId installation via a `Rails::Railtie` so apps that bundle the gem don't need an explicit initializer.

## Quick Reference

```bash
# Run tests
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/standard_id/google/providers/google_spec.rb

# Run linting (note: --config flag is required on Ruby 4.0)
bundle exec rubocop --config .rubocop.yml

# Auto-fix lint issues
bundle exec rubocop --config .rubocop.yml -A
```

## Project Structure

```
standard_id-google/
├── lib/standard_id/
│   ├── google.rb                        # Top-level require entrypoint
│   └── google/
│       ├── version.rb                   # Gem version constant
│       ├── railtie.rb                   # Auto-registers provider on after_initialize
│       └── providers/google.rb          # StandardId::Providers::Google implementation
└── spec/
    ├── spec_helper.rb                   # Boots a minimal Rails app so the Railtie fires
    └── standard_id/                     # Provider specs
```

## Key Patterns

### Provider class

`StandardId::Providers::Google` inherits from `StandardId::Providers::Base` (defined in the parent `standard_id` gem) and implements the provider contract: `provider_name`, `authorization_url`, `get_user_info`, `config_schema`, plus Google-specific helpers (`verify_id_token`, `fetch_user_info`, code/token exchange via Google's tokeninfo + userinfo endpoints).

### Railtie auto-registration

`StandardId::Google::Railtie` runs on `config.after_initialize` and calls `StandardId::ProviderRegistry.register(:google, StandardId::Providers::Google)`. Host apps just need the gem in their Gemfile — no initializer required.

### Spec bootstrapping

`spec/spec_helper.rb` defines a tiny `Rails::Application` and calls `Rails.application.initialize!` so the Railtie's `after_initialize` hook fires during the spec run; without this the provider would not appear in the registry.

## Key Files

| File | Purpose |
|------|---------|
| `lib/standard_id/google.rb` | Top-level require entrypoint |
| `lib/standard_id/google/railtie.rb` | Provider registration on Rails boot |
| `lib/standard_id/google/providers/google.rb` | Google provider implementation |
| `lib/standard_id/google/version.rb` | Gem version constant |
| `standard_id-google.gemspec` | Gem metadata + runtime deps |

## Dependencies

- **standard_id** `~> 0.1`, `>= 0.1.7` (parent engine — provides `Providers::Base`, `ProviderRegistry`, `HttpClient`, errors)
- **activesupport** `>= 8.0` (`present?`/`blank?`, indifferent access)

Dev: rspec, rubocop, webmock, lefthook.

## Testing

- WebMock stubs Google's tokeninfo and userinfo endpoints — never make real network calls in specs.
- The dummy Rails app in `spec_helper.rb` is intentionally minimal; add config via `StandardId.config.google_*` setters in individual specs rather than expanding the dummy app.
- CI runs the full Ruby 4.0.x patch matrix via the shared `rarebit-one/.github` reusable workflow.
