# frozen_string_literal: true

require "rails/generators"

module StandardId
  module Google
    module Generators
      # Installs the Google provider's credentials block in a host Rails app.
      #
      # Writes `config/initializers/standard_id_google.rb` — a separate file
      # from `config/initializers/standard_id.rb` on purpose. The provider is
      # opt-in per app, so its credentials should be removable by deleting one
      # file, and `standard_id`'s own install generator must stay free to
      # overwrite its initializer without clobbering these values.
      #
      # Initializers load alphabetically, so `standard_id.rb` runs before
      # `standard_id_google.rb` — the base configuration is already applied by
      # the time this file sets the `social.google_*` fields.
      #
      # Idempotent: re-running skips an initializer that is already there.
      # `--skip-initializer` opts out; `--force` overwrites.
      class InstallGenerator < Rails::Generators::Base
        source_root File.expand_path("templates", __dir__)

        INITIALIZER_PATH = "config/initializers/standard_id_google.rb"

        desc <<~DESC
          Installs StandardId Google. This writes #{INITIALIZER_PATH} with the
          social.google_* fields wired to ENV, and prints the env vars the host
          needs to set.

          The generator is idempotent — an existing initializer is skipped with
          a clear message. Pass --force to overwrite.
        DESC

        class_option :skip_initializer, type: :boolean, default: false,
          desc: "Do not write #{INITIALIZER_PATH}"
        class_option :force, type: :boolean, default: false,
          desc: "Overwrite #{INITIALIZER_PATH} if it already exists"

        def copy_initializer
          if options[:skip_initializer]
            say_status("skip", "#{INITIALIZER_PATH} (--skip-initializer)", :yellow)
            return
          end

          if File.exist?(File.join(destination_root, INITIALIZER_PATH)) && !options[:force]
            say_status("identical", "#{INITIALIZER_PATH} (already exists; pass --force to overwrite)", :blue)
            return
          end

          template "initializer.rb.erb", INITIALIZER_PATH, force: options[:force]
        end

        def print_env_hint
          return if options[:skip_initializer]

          say ""
          say "=" * 79
          say "StandardId Google installed."
          say ""
          say "Set these in the host's environment (1Password / DO app spec / .env):"
          say ""
          say "  GOOGLE_OAUTH_CLIENT_ID      the OAuth 2.0 Web application client ID"
          say "  GOOGLE_OAUTH_CLIENT_SECRET  its client secret"
          say ""
          say "Register /auth/callback/google as an authorized redirect URI in the"
          say "Google Cloud console for EVERY origin you serve — the console matches"
          say "the redirect exactly, so staging and production each need their own."
          say "=" * 79
          say ""
        end
      end
    end
  end
end
