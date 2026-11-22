# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "jwt"

# standard_id releases after 0.60.0 take `provider:` on HttpClient (for the
# host's config.network_wrapper); older ones raise ArgumentError on it. The
# provider must pass it to the first and leave it out for the second. Each
# context swaps in an HttpClient subclass with one signature, so both paths are
# covered whichever standard_id the bundle resolves.
RSpec.describe StandardId::Providers::Google, "HttpClient provider: keyword" do
  let(:google_client_id) { "google_client_123" }
  let(:access_token) { "exchanged_access_token" }
  let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }

  before do
    allow(StandardId.config).to receive_messages(google_client_id: google_client_id, google_client_secret: "google_secret")
    allow(Resolv).to receive(:getaddresses).and_return(["142.250.0.1"])
    described_class.reset_jwks_cache!

    stub_request(:post, "https://oauth2.googleapis.com/token")
      .to_return(status: 200, body: { access_token: access_token, token_type: "Bearer" }.to_json)
    stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
      .to_return(status: 200, body: { aud: google_client_id, sub: "123456" }.to_json)
    stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
      .with(headers: { "Authorization" => "Bearer #{access_token}" })
      .to_return(status: 200, body: { sub: "123456", email: "user@example.com" }.to_json)
    stub_request(:get, described_class::JWKS_URI)
      .to_return(status: 200, body: { keys: [JWT::JWK.new(rsa_key, { kid: "kid-1" }).export] }.to_json)

    stub_const("StandardId::HttpClient", client)
  end

  def exercise_every_call
    described_class.exchange_code_for_user_info(code: "code-1", redirect_uri: "https://example.com/callback")
    now = Time.now.to_i
    id_token = JWT.encode(
      { iss: "https://accounts.google.com", aud: google_client_id, sub: "123456", iat: now, exp: now + 600 },
      rsa_key, "RS256", { kid: "kid-1" }
    )
    described_class.verify_id_token(id_token: id_token)
  end

  # Stand-ins for HttpClient with one fixed signature each. They delegate to
  # the real class (captured before stub_const) rather than subclassing it, so
  # the real methods' internal calls never land on the stand-in.
  let(:real_client) { StandardId::HttpClient }

  context "with a standard_id whose HttpClient takes provider:" do
    let(:calls) { [] }
    let(:client) do
      real = real_client
      recorded = calls
      Class.new do
        define_singleton_method(:post_form) do |endpoint, params = nil, provider: :standard_id, **form|
          recorded << [:post_form, provider]
          real.post_form(endpoint, (params || {}).merge(form))
        end

        define_singleton_method(:get_with_bearer) do |endpoint, token, provider: :standard_id|
          recorded << [:get_with_bearer, provider]
          real.get_with_bearer(endpoint, token)
        end

        define_singleton_method(:validate_url!) { |url| real.send(:validate_url!, url) }
        define_singleton_method(:start_connection) do |uri, resolved_ip: nil, provider: :standard_id, &block|
          recorded << [:start_connection, provider]
          real.send(:start_connection, uri, resolved_ip: resolved_ip, &block)
        end
        private_class_method :validate_url!, :start_connection
      end
    end

    it "names :google on every request: token exchange, tokeninfo, userinfo and the JWKS" do
      exercise_every_call

      expect(calls).to eq([
        %i[post_form google],
        %i[post_form google],
        %i[get_with_bearer google],
        %i[start_connection google]
      ])
    end

    it "names :google on the legacy tokeninfo ID-token check" do
      allow(StandardId.config).to receive(:google_id_token_verification).and_return("tokeninfo")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { id_token: "legacy-token" })
        .to_return(status: 200, body: { aud: google_client_id, sub: "123456", iss: "accounts.google.com" }.to_json)

      described_class.verify_id_token(id_token: "legacy-token")

      expect(calls).to eq([%i[post_form google]])
    end
  end

  context "with a standard_id whose HttpClient has no provider: keyword (0.60.0 and older)" do
    let(:client) do
      real = real_client
      Class.new do
        define_singleton_method(:post_form) { |endpoint, params| real.post_form(endpoint, params) }
        define_singleton_method(:get_with_bearer) { |endpoint, token| real.get_with_bearer(endpoint, token) }
        define_singleton_method(:validate_url!) { |url| real.send(:validate_url!, url) }
        define_singleton_method(:start_connection) do |uri, resolved_ip: nil, &block|
          real.send(:start_connection, uri, resolved_ip: resolved_ip, &block)
        end
        private_class_method :validate_url!, :start_connection
      end
    end

    it "makes every request without passing provider:" do
      result = exercise_every_call

      expect(result["sub"]).to eq("123456")
      expect(WebMock).to have_requested(:post, "https://oauth2.googleapis.com/token")
      expect(WebMock).to have_requested(:post, "https://oauth2.googleapis.com/tokeninfo").with(body: { access_token: access_token })
      expect(WebMock).to have_requested(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
      expect(WebMock).to have_requested(:get, described_class::JWKS_URI)
    end
  end
end
