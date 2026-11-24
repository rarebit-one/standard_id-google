# frozen_string_literal: true

# Offers the plugin's env vars to standard_health without depending on it.
# The block runs only when standard_health is loaded (it fires
# `run_load_hooks(:standard_health, ...)`), whichever gem loads first; without
# standard_health it never runs. It receives standard_health's contribution
# registry, of which only `contribute_env_vars` is used here.
#
# The provider stays off until google_client_id is set, so nothing here is
# required unconditionally: GOOGLE_CLIENT_SECRET becomes required only once the
# provider is on and the app leaves the field to its ENV fallback. An app that
# declares any of these vars in its own env_spec overrides the row here.
ActiveSupport.on_load(:standard_health) do |health|
  google = StandardId::Providers::Google

  # Whether +field+ is left to its ENV fallback: the app never assigned it
  # (standard_id < 0.43 can't tell, so it counts as unassigned) and the
  # deprecated pre-0.5.0 name isn't supplying it either. An app that assigns
  # the field, from credentials say, needs no ENV var for it.
  from_env = lambda do |field|
    social = StandardId.config.social
    assigned = social.respond_to?(:assigned?) && social.assigned?(field)
    !assigned && ENV[google::LEGACY_ENV.fetch(field)].blank?
  end

  health.contribute_env_vars "standard_id-google" do
    recommended :GOOGLE_CLIENT_ID,
      description: "Google OAuth client ID (social.google_client_id). Setting it switches Sign in with Google " \
                   "on; unset leaves the provider off. Replaces the deprecated GOOGLE_OAUTH_CLIENT_ID"
    required :GOOGLE_CLIENT_SECRET,
      if: -> { google.enabled? && from_env.call(:google_client_secret) },
      description: "Google OAuth client secret (social.google_client_secret). Required once GOOGLE_CLIENT_ID " \
                   "switches the provider on, unless the app assigns the field itself. Replaces the deprecated " \
                   "GOOGLE_OAUTH_CLIENT_SECRET"
    # On by default; setting it false turns StandardId::Google.staff_policy
    # off, letting staff in by any login method. Flag that on production.
    forbidden :GOOGLE_REQUIRE_FOR_STAFF, in: %w[production],
      if: -> { StandardId.config.google_require_for_staff == false },
      description: "Overrides social.google_require_for_staff (default true). Set false, it switches off " \
                   "StandardId::Google.staff_policy, so staff are no longer held to a pinned Google sign-in"
  end
end
