# StandardId Google Provider

This gem extracts the Google OAuth provider from the core [`standard_id`](https://github.com/rarebit-one/standard_id) engine so installations can opt into Google login independently of the base gem.

## Installation

Requires `standard_id` 0.42 or later.

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

Then run the install generator to drop the credentials block in place:

```bash
bin/rails g standard_id:google:install
```

This writes `config/initializers/standard_id_google.rb` — deliberately a
separate file from `config/initializers/standard_id.rb`, so the provider can be
removed by deleting one file and `standard_id`'s own install generator stays
free to overwrite its initializer without clobbering these values. Initializers
load alphabetically, so the base config is applied first. The generator is
idempotent; re-running on an existing initializer skips with a clear message
(pass `--force` to overwrite).

## Configuration

The generator writes this for you; the block is documented here for hosts
configuring by hand. Configure your Google credentials inside the StandardId
configuration block:

```ruby
# config/initializers/standard_id_google.rb
StandardId.configure do |config|
  config.social.google_client_id = ENV.fetch("GOOGLE_CLIENT_ID", nil)
  config.social.google_client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET", nil)
end
```

With those values in place, StandardId routes such as `/auth/callback/google` continue to function using this provider gem.

### ENV fallback

On `standard_id` 0.42+, a field you never assign falls back to the ENV
variable named after it, upper-cased:

| Field | ENV variable | Deprecated fallback |
|---|---|---|
| `google_client_id` | `GOOGLE_CLIENT_ID` | `GOOGLE_OAUTH_CLIENT_ID` |
| `google_client_secret` | `GOOGLE_CLIENT_SECRET` | `GOOGLE_OAUTH_CLIENT_SECRET` |

So with those variables set the block above is optional. Explicit
configuration, even `nil`, always wins. The `GOOGLE_OAUTH_*` names — what
install generators before 0.5.0 wrote — are still read when the canonical
variable is unset and the field is never assigned, with a deprecation warning;
rename them. (An initializer that assigns `ENV.fetch("GOOGLE_OAUTH_CLIENT_ID")`
explicitly keeps working as-is.)

### Required fields and the boot check

`google_client_id` switches the provider on — it is what
`StandardId.social_provider_enabled?(:google)` and the `google_enabled` Inertia
prop report. While it is set, `google_client_secret` is required: the web
sign-in's code exchange needs it, so without it the user authenticates with
Google and only then does the callback fail. StandardId checks this once every
plugin has registered:

```ruby
StandardId::Providers::Google.configuration_errors
# => ["google_client_secret is required when google_client_id is set"]

config.social.provider_misconfiguration = :raise # fail a production boot instead of warning
```

### Flows

| Flow | Needs `google_client_secret` |
|---|---|
| Web (`/auth/callback/google`, authorization code) | yes |
| Native `id_token` (`/api/oauth/callback/google`) | no |
| Native `access_token` | no |

ID tokens and access tokens are both checked against Google's tokeninfo
endpoint (`https://oauth2.googleapis.com/tokeninfo`), then against this app's
client ID. An app that only accepts native ID tokens can run without a client
secret; it will get the boot warning above, because an enabled provider shows
the web sign-in button — leave `provider_misconfiguration` at `:warn` there.

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
    config.social.google_client_id = ENV.fetch("GOOGLE_CLIENT_ID", nil)
    config.social.google_client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET", nil)
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

In a host app, pin the plugin's registration with standard_id's shared
example:

```ruby
require "standard_id/testing"

RSpec.describe "StandardId social providers" do
  it_behaves_like "a registered StandardId provider", :google
end
```

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
