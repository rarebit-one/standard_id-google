require "active_support/core_ext/numeric/time"
require "active_support/core_ext/hash/indifferent_access"
require "standard_id"
require "standard_id/google/version"
require "standard_id/google/providers/google"

# Registers the provider from a Railtie's after_initialize (a no-op outside
# Rails). Its config fields are declared earlier, before config/initializers,
# by standard_id's own engine initializer.
StandardId::Providers.plugin_railtie(:google, "StandardId::Providers::Google")
