# frozen_string_literal: true

module StandardId
  module Google
    class Railtie < ::Rails::Railtie
      config.after_initialize do
        StandardId::ProviderRegistry.register(:google, StandardId::Providers::Google)

        Rails.logger.debug("[StandardId::Google] registered provider") if Rails.logger
      end
    end
  end
end
