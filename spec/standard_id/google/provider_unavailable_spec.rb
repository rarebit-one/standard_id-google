# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "jwt"

# When the host's config.network_wrapper refuses a request itself (an open
# circuit), standard_id releases with StandardId::NetworkWrapper raise
# StandardId::ProviderUnavailableError, an OAuthError. Every Google request
# runs inside rescue_to_oauth_error, which passes OAuthErrors through, so core
# sees the marker and shows "Google is temporarily unavailable" (API: 503)
# rather than a 500. These examples pin that, so a refactor that moves a
# request outside rescue_to_oauth_error, or re-wraps the marker, is caught.
RSpec.describe StandardId::Providers::Google, "network_wrapper refusals" do
  let(:google_client_id) { "google_client_123" }
  let(:access_token) { "exchanged_access_token" }
  let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:real_client) { StandardId::HttpClient }
  let(:verification) { nil }

  before do
    allow(StandardId.config).to receive_messages(
      google_client_id: google_client_id, google_client_secret: "google_secret",
      google_id_token_verification: verification
    )
    allow(Resolv).to receive(:getaddresses).and_return(["142.250.0.1"])
    described_class.reset_jwks_cache!

    stub_request(:post, "https://oauth2.googleapis.com/token")
      .to_return(status: 200, body: { access_token: access_token, token_type: "Bearer" }.to_json)
    stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
      .to_return(status: 200, body: { aud: google_client_id, sub: "123456", iss: "https://accounts.google.com" }.to_json)
    stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
      .with(headers: { "Authorization" => "Bearer #{access_token}" })
      .to_return(status: 200, body: { sub: "123456", email: "user@example.com" }.to_json)
    stub_request(:get, described_class::JWKS_URI)
      .to_return(status: 200, body: { keys: [JWT::JWK.new(rsa_key, { kid: "kid-1" }).export] }.to_json)
  end

  def id_token
    now = Time.now.to_i
    JWT.encode(
      { iss: "https://accounts.google.com", aud: google_client_id, sub: "123456", iat: now, exp: now + 600 },
      rsa_key, "RS256", { kid: "kid-1" }
    )
  end

  # Each sign-in entry point, as core's callback calls it.
  def sign_in_flows
    {
      "the code exchange" => -> { described_class.get_user_info(code: "code-1", redirect_uri: "https://example.com/callback") },
      "an id_token (JWKS)" => -> { described_class.get_user_info(id_token: id_token) },
      "an access_token (tokeninfo + userinfo)" => -> { described_class.get_user_info(access_token: access_token) }
    }
  end

  # An HttpClient stand-in whose every call raises `error` without making the
  # request (what a refusing wrapper does). It takes no provider: keyword, so
  # it works with every release.
  def refusing_client(error)
    Class.new do
      define_singleton_method(:post_form) { |*_args, **_kw| raise error.call }
      define_singleton_method(:get_with_bearer) { |*_args, **_kw| raise error.call }
      define_singleton_method(:validate_url!) { |url| [URI.parse(url), "142.250.0.1"] }
      define_singleton_method(:start_connection) { |*_args, **_kw, &_block| raise error.call }
      private_class_method :validate_url!, :start_connection
    end
  end

  context "with a standard_id that raises ProviderUnavailableError" do
    before do
      unless defined?(StandardId::ProviderUnavailableError)
        stub_const("StandardId::ProviderUnavailableError", Class.new(StandardId::OAuthError))
      end
      stub_const("StandardId::HttpClient", refusing_client(-> { StandardId::ProviderUnavailableError.new("Google is temporarily unavailable") }))
    end

    it "passes the refusal through every sign-in flow unchanged" do
      sign_in_flows.each do |flow, call|
        expect { call.call }.to raise_error(StandardId::ProviderUnavailableError, "Google is temporarily unavailable"), flow
      end
    end

    context "with tokeninfo id_token verification" do
      let(:verification) { "tokeninfo" }

      it "passes the refusal through unchanged" do
        expect { described_class.get_user_info(id_token: id_token) }
          .to raise_error(StandardId::ProviderUnavailableError, "Google is temporarily unavailable")
      end
    end
  end

  context "with a standard_id that has no ProviderUnavailableError" do
    before { hide_const("StandardId::ProviderUnavailableError") }

    it "still fails sign-in with an OAuthError (not a 500) when the wrapper raises its own error" do
      circuit_open = Class.new(StandardError)
      stub_const("StandardId::HttpClient", refusing_client(-> { circuit_open.new("open") }))

      sign_in_flows.each do |flow, call|
        expect { call.call }.to raise_error(StandardId::OAuthError) { |error| expect(error.cause).to be_a(circuit_open) }, flow
      end
    end
  end

  # Against the real HttpClient and the host's wrapper; needs a standard_id
  # with StandardId::NetworkWrapper (run with a path override until released).
  context "with the host's network_wrapper" do
    before do
      skip "needs a standard_id with StandardId::NetworkWrapper" unless defined?(StandardId::NetworkWrapper)
      allow(StandardId.config).to receive(:network_wrapper).and_return(wrapper)
    end

    context "when the wrapper refuses without calling the block (an open circuit)" do
      let(:circuit_open) { Class.new(StandardError) }
      let(:wrapper) do
        error = circuit_open
        ->(provider:, &_block) { raise error, "oauth_#{provider} is open" }
      end

      it "fails every sign-in flow with ProviderUnavailableError for :google, making no request" do
        sign_in_flows.each do |flow, call|
          expect { call.call }.to raise_error(StandardId::ProviderUnavailableError, "Google is temporarily unavailable") { |error|
            expect(error.provider).to eq(:google)
            expect(error.cause).to be_a(circuit_open)
          }, flow
        end
        expect(WebMock).not_to have_requested(:any, /google/)
      end
    end

    context "when the wrapper calls the block" do
      let(:wrapper) { ->(provider:, &block) { block.call } }

      it "behaves exactly as without a wrapper" do
        results = sign_in_flows.transform_values(&:call)

        expect(results.values.map { |result| result[:user_info]["sub"] }).to eq(%w[123456 123456 123456])
      end

      it "still turns a transport error raised inside the wrapper into a plain OAuthError" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_timeout

        expect {
          described_class.get_user_info(code: "code-1", redirect_uri: "https://example.com/callback")
        }.to raise_error(StandardId::OAuthError) { |error|
          expect(error).not_to be_a(StandardId::ProviderUnavailableError)
          expect(error.cause).to be_a(Net::OpenTimeout)
        }
      end
    end
  end
end
