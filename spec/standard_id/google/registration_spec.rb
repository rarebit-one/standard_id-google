# frozen_string_literal: true

require "spec_helper"
require "standard_id/testing/provider_examples"

RSpec.describe "standard_id-google registration" do
  it_behaves_like "a registered StandardId provider", :google

  it "registers StandardId::Providers::Google" do
    expect(StandardId::ProviderRegistry.get(:google)).to eq(StandardId::Providers::Google)
  end

  it "declares every field on the social scope" do
    expect(:google).to be_a_registered_standard_id_provider.with_config_fields(:google_client_id, :google_client_secret)
  end

  it "is registered by the Railtie standard_id's plugin_railtie defines" do
    expect(StandardId::Providers::Railties::Google).to be < Rails::Railtie
  end
end
