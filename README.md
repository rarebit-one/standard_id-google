# StandardId Google Provider

This gem extracts the Google OAuth provider from the core [`standard_id`](https://github.com/rarebit-one/standard_id) engine so installations can opt into Google login independently of the base gem.

## Installation

Add the gem next to `standard_id`:

```ruby
# Gemfile
gem "standard_id"
gem "standard_id-google"
```

Then run:

```bash
bundle install
```

The gem automatically registers itself with StandardId when it is required.

## Configuration

Configure your Google credentials inside the StandardId configuration block:

```ruby
# config/initializers/standard_id.rb
StandardId.configure do |config|
  config.social.google_client_id = ENV.fetch("GOOGLE_OAUTH_CLIENT_ID", nil)
  config.social.google_client_secret = ENV.fetch("GOOGLE_OAUTH_CLIENT_SECRET", nil)
end
```

With those values in place, StandardId routes such as `/auth/callback/google` continue to function using this provider gem.

### Boot ordering (standard_id <= 0.32.0)

These fields are declared by *this gem*, not by `standard_id`, and until
`standard_id` 0.33.0 they were declared from this gem's Railtie
`after_initialize` — which runs *after* `config/initializers`. On `standard_id`
**0.32.0 and earlier** the block above therefore raised:

```
StandardId::ConfigurationError: Unknown field 'google_client_id' for scope 'social'
```

The workaround was to wrap the writes:

```ruby
# Only needed on standard_id <= 0.32.0
Rails.application.config.after_initialize do
  StandardId.configure do |config|
    config.social.google_client_id = ENV.fetch("GOOGLE_OAUTH_CLIENT_ID", nil)
    config.social.google_client_secret = ENV.fetch("GOOGLE_OAUTH_CLIENT_SECRET", nil)
  end
end
```

`standard_id` **>= 0.33.0** declares every loaded provider's fields before
`:load_config_initializers`, so a plain initializer is correct. The wrapper is no
longer needed and existing ones keep working unchanged.

Note this is about *ordering*, not just versions: **the fields do not exist
without this gem in your Gemfile**, on any `standard_id` version. Configuring
`social.google_*` with the plugin absent raises the same error, correctly.

## Testing

Run the provider test suite with:

```bash
bundle exec rspec
```

## Development

1. `bin/setup`
2. `bundle exec rspec`

To release a new version:

1. Update the version in `lib/standard_id/google/version.rb`.
2. Run `bundle exec rake release` to tag, push, and publish to RubyGems.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).
