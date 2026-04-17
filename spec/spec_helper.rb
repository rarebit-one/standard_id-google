# frozen_string_literal: true

require "rails"
require "webmock/rspec"
require "standard_id/google"

# Boot a minimal Rails application so Railties (including the plugin's own
# provider-registration Railtie) fire their `config.after_initialize` hooks.
# Without this, `Rails.application.initialize!` is never invoked and the
# provider never makes it into the registry during the spec suite.
module StandardIdGoogleTest
  class Application < ::Rails::Application
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = "test_secret_key_base"
  end
end

Rails.application.initialize!

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
