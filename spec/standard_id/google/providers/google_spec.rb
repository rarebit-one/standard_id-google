# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardId::Providers::Google do
  let(:google_client_id) { "google_client_123" }
  let(:google_client_secret) { "google_secret" }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return(google_client_id)
    allow(StandardId.config).to receive(:google_client_secret).and_return(google_client_secret)
  end

  describe "interface compliance" do
    it "inherits from Base" do
      expect(described_class).to be < StandardId::Providers::Base
    end
  end

  describe ".provider_name" do
    it 'returns "google"' do
      expect(described_class.provider_name).to eq("google")
    end
  end

  describe ".default_scope" do
    it 'returns "openid email profile"' do
      expect(described_class.default_scope).to eq("openid email profile")
    end
  end

  describe ".authorization_url" do
    let(:state) { "encoded_state_value" }
    let(:redirect_uri) { "https://example.com/callback" }

    it "generates a valid Google OAuth URL" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        prompt: "select_account"
      )

      expect(url).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
      expect(url).to include("client_id=#{google_client_id}")
      expect(url).to include("redirect_uri=#{CGI.escape(redirect_uri)}")
      expect(url).to include("response_type=code")
      expect(url).to include("scope=openid+email+profile")
      expect(url).to include("state=#{state}")
      expect(url).to include("prompt=select_account")
    end

    it "accepts custom scope" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        scope: "email profile"
      )

      expect(url).to include("scope=email+profile")
    end

    it "omits prompt parameter when nil" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        prompt: nil
      )

      expect(url).not_to include("prompt=")
    end

    it "accepts multiple extra parameters" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        login_hint: "user@example.com",
        prompt: "consent",
        access_type: "offline",
        hd: "example.com",
        response_mode: "form_post",
        nonce: "random_nonce_value"
      )

      expect(url).to include("login_hint=user%40example.com")
      expect(url).to include("prompt=consent")
      expect(url).to include("access_type=offline")
      expect(url).to include("hd=example.com")
      expect(url).to include("response_mode=form_post")
      expect(url).to include("nonce=random_nonce_value")
    end
  end

  describe ".get_user_info" do
    context "with id_token" do
      let(:id_token) { "mobile_id_token" }
      let(:nonce) { "random_nonce_value" }
      let(:user_info) { { "email" => "user@example.com", "name" => "Test User" } }

      it "verifies id_token directly" do
        expect(described_class).to receive(:verify_id_token)
          .with(id_token:, nonce:)
          .and_return(user_info)

        result = described_class.get_user_info(id_token:, nonce:)

        expect(result[:user_info]).to eq(user_info)
        expect(result[:tokens]).to eq({ id_token: }.with_indifferent_access)
      end
    end

    context "with access_token" do
      let(:access_token) { "mobile_access_token" }
      let(:user_info) { { "email" => "user@example.com", "name" => "Test User" } }

      it "fetches user info directly" do
        expect(described_class).to receive(:fetch_user_info)
          .with(access_token: access_token)
          .and_return(user_info)

        result = described_class.get_user_info(access_token: access_token)

        expect(result[:user_info]).to eq(user_info)
        expect(result[:tokens]).to eq({ access_token: access_token }.with_indifferent_access)
      end
    end

    context "with code" do
      let(:code) { "authorization_code_123" }
      let(:nonce) { "random_nonce_value" }
      let(:redirect_uri) { "https://example.com/callback" }
      let(:user_info) { { "email" => "user@example.com", "name" => "Test User" } }

      it "exchanges code for user info" do
        expect(described_class).to receive(:exchange_code_for_user_info)
          .with(code:, nonce:, redirect_uri: redirect_uri)
          .and_return({ user_info:, tokens: { access_token: "exchanged" } })

        result = described_class.get_user_info(code:, redirect_uri:, nonce:)

        expect(result[:user_info]).to eq(user_info)
        expect(result[:tokens]).to include(:access_token)
      end
    end

    context "without code, id_token, or access_token" do
      it "raises an error" do
        expect do
          described_class.get_user_info
        end.to raise_error(StandardId::InvalidRequestError, "Google sign-in requires a code, an id_token or an access_token")
      end
    end
  end

  describe ".exchange_code_for_user_info" do
    let(:code) { "authorization_code_123" }
    let(:redirect_uri) { "https://example.com/callback" }
    let(:access_token) { "exchanged_access_token" }
    let(:user_info) { { "email" => "user@example.com", "name" => "Test User", "sub" => "123456" } }

    it "exchanges code for access token and fetches user info" do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .with(body: hash_including(
          client_id: google_client_id,
          client_secret: google_client_secret,
          code: code,
          grant_type: "authorization_code",
          redirect_uri: redirect_uri
        )).to_return(status: 200, body: { access_token: access_token, token_type: "Bearer" }.to_json)

      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: { aud: google_client_id, sub: "123456" }.to_json)

      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
        .with(headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(status: 200, body: user_info.to_json)

      result = described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)

      expect(result[:user_info]).to eq(user_info)
      expect(result[:tokens]).to include(access_token: access_token)
    end

    it "raises error when code is blank" do
      expect do
        described_class.exchange_code_for_user_info(code: "", redirect_uri: redirect_uri)
      end.to raise_error(StandardId::InvalidRequestError, "Google authorization code is missing")
    end

    it "raises error when token exchange fails" do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json)

      expect do
        described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
      end.to raise_error(StandardId::InvalidRequestError, "Failed to exchange Google authorization code: invalid_grant")
    end

    it "falls back to the HTTP status when the body names no error" do
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 502, body: "<html>")

      expect do
        described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
      end.to raise_error(StandardId::InvalidRequestError, "Failed to exchange Google authorization code: HTTP 502")
    end

    it "requires the client secret, without calling Google" do
      allow(StandardId.config).to receive(:google_client_secret).and_return(nil)

      expect do
        described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
      end.to raise_error(StandardId::InvalidRequestError, "Google OAuth credentials are incomplete: google_client_secret not set")
      expect(WebMock).not_to have_requested(:post, "https://oauth2.googleapis.com/token")
    end

    it "wraps non-OAuth errors in StandardId::OAuthError, keeping the cause" do
      allow(StandardId::HttpClient).to receive(:post_form).and_raise(Errno::ECONNRESET)

      expect do
        described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
      end.to raise_error(StandardId::OAuthError) { |error| expect(error.cause).to be_a(Errno::ECONNRESET) }
    end

    context "when the token response carries an id_token and a nonce was issued" do
      before do
        stub_request(:post, "https://oauth2.googleapis.com/token")
          .to_return(status: 200, body: { access_token: access_token, id_token: "web_id_token" }.to_json)
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
          .with(body: { access_token: access_token })
          .to_return(status: 200, body: { aud: google_client_id }.to_json)
        stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo").to_return(status: 200, body: user_info.to_json)
      end

      def stub_id_token_info(nonce)
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
          .with(body: { id_token: "web_id_token" })
          .to_return(status: 200, body: { aud: google_client_id, iss: "https://accounts.google.com", nonce: nonce }.to_json)
      end

      it "accepts a matching nonce and returns every token" do
        stub_id_token_info("server-nonce")

        result = described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri, nonce: "server-nonce")

        expect(result[:tokens]).to eq({ access_token: access_token, id_token: "web_id_token" }.with_indifferent_access)
      end

      it "rejects a mismatched nonce" do
        stub_id_token_info("other-nonce")

        expect do
          described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri, nonce: "server-nonce")
        end.to raise_error(StandardId::InvalidRequestError, "ID token nonce mismatch")
      end
    end

    it "raises error when access_token is missing from response" do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 200, body: {}.to_json)

      expect do
        described_class.exchange_code_for_user_info(code: code, redirect_uri: redirect_uri)
      end.to raise_error(StandardId::InvalidRequestError, "Google token response is missing access_token")
    end
  end

  describe ".verify_id_token" do
    let(:id_token) { "valid_id_token" }
    let(:token_info) do
      {
        iss: "accounts.google.com",
        aud: google_client_id,
        sub: "123456789",
        email: "user@example.com",
        email_verified: "true",
        name: "Test User",
        given_name: "Test",
        family_name: "User",
        picture: "https://lh3.googleusercontent.com/a/default-user",
        locale: "en"
      }
    end

    it "verifies id_token and returns user info" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { id_token: id_token })
        .to_return(status: 200, body: token_info.to_json)

      result = described_class.verify_id_token(id_token: id_token)

      expect(result["sub"]).to eq("123456789")
      expect(result["email"]).to eq("user@example.com")
      expect(result["name"]).to eq("Test User")
    end

    it "raises error when id_token is blank" do
      expect do
        described_class.verify_id_token(id_token: "")
      end.to raise_error(StandardId::InvalidRequestError, "Google id_token is missing")
    end

    it "raises error when id_token verification fails" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 400, body: { error: "invalid_token" }.to_json)

      expect do
        described_class.verify_id_token(id_token: id_token)
      end.to raise_error(StandardId::InvalidRequestError, "Invalid Google ID token: invalid or expired")
    end

    it "raises error when audience mismatches" do
      mismatched_token_info = token_info.merge(aud: "wrong_client_id")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: mismatched_token_info.to_json)

      expect do
        described_class.verify_id_token(id_token: id_token)
      end.to raise_error(StandardId::InvalidRequestError, "Invalid Google ID token audience")
    end

    it "does not echo the configured or presented audience" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: token_info.merge(aud: "attacker.apps.googleusercontent.com").to_json)

      expect do
        described_class.verify_id_token(id_token: id_token)
      end.to raise_error(StandardId::InvalidRequestError) { |error|
        expect(error.message).not_to include(google_client_id)
        expect(error.message).not_to include("attacker")
      }
    end

    it "rejects a token with no audience" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: token_info.except(:aud).to_json)

      expect do
        described_class.verify_id_token(id_token: id_token)
      end.to raise_error(StandardId::InvalidRequestError, "Invalid Google ID token audience")
    end

    context "without a client secret (id_token-only deployment)" do
      before { allow(StandardId.config).to receive(:google_client_secret).and_return(nil) }

      it "still verifies the id_token" do
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
          .with(body: { id_token: id_token })
          .to_return(status: 200, body: token_info.to_json)

        expect(described_class.get_user_info(id_token: id_token)[:user_info]["sub"]).to eq("123456789")
      end
    end

    context "without a client ID" do
      before { allow(StandardId.config).to receive(:google_client_id).and_return(nil) }

      it "refuses" do
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo").to_return(status: 200, body: token_info.to_json)

        expect do
          described_class.verify_id_token(id_token: id_token)
        end.to raise_error(StandardId::InvalidRequestError, "Google OAuth is not configured")
      end
    end

    describe "nonce" do
      let(:expected_nonce) { "server-issued-nonce-4f1c" }

      it "accepts a matching nonce" do
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
          .to_return(status: 200, body: token_info.merge(nonce: expected_nonce).to_json)

        expect(described_class.verify_id_token(id_token: id_token, nonce: expected_nonce)["sub"]).to eq("123456789")
      end

      it "rejects a mismatched nonce without echoing either value" do
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
          .to_return(status: 200, body: token_info.merge(nonce: "attacker-nonce-9z").to_json)

        expect do
          described_class.verify_id_token(id_token: id_token, nonce: expected_nonce)
        end.to raise_error(StandardId::InvalidRequestError) { |error|
          expect(error.message).to eq("ID token nonce mismatch")
          expect(error.message).not_to include(expected_nonce)
          expect(error.message).not_to include("attacker-nonce-9z")
        }
      end

      it "rejects a token with no nonce when one was issued" do
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo").to_return(status: 200, body: token_info.to_json)

        expect do
          described_class.verify_id_token(id_token: id_token, nonce: expected_nonce)
        end.to raise_error(StandardId::InvalidRequestError, "ID token nonce mismatch")
      end

      it "skips the check when no nonce was issued (native flow)" do
        stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
          .to_return(status: 200, body: token_info.merge(nonce: "client-side").to_json)

        expect(described_class.verify_id_token(id_token: id_token)["sub"]).to eq("123456789")
      end
    end

    it "raises error when issuer is invalid" do
      invalid_issuer_token_info = token_info.merge(iss: "evil.com")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: invalid_issuer_token_info.to_json)

      expect do
        described_class.verify_id_token(id_token: id_token)
      end.to raise_error(StandardId::InvalidRequestError, "Invalid Google ID token issuer")
    end

    it "works with https:// prefixed issuer" do
      https_issuer_token_info = token_info.merge(iss: "https://accounts.google.com")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { id_token: id_token })
        .to_return(status: 200, body: https_issuer_token_info.to_json)

      result = described_class.verify_id_token(id_token: id_token)
      expect(result["email"]).to eq("user@example.com")
    end
  end

  describe ".fetch_user_info" do
    let(:access_token) { "valid_access_token" }
    let(:user_info) { { "email" => "user@example.com", "name" => "Test User", "sub" => "123456" } }

    it "verifies token and fetches user info" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: { aud: google_client_id, sub: "123456" }.to_json)

      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
        .with(headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(status: 200, body: user_info.to_json)

      result = described_class.fetch_user_info(access_token: access_token)
      expect(result).to eq(user_info)
    end

    it "raises error when access_token is blank" do
      expect do
        described_class.fetch_user_info(access_token: "")
      end.to raise_error(StandardId::InvalidRequestError, "Google access token is missing")
    end

    it "raises error when user info fetch fails" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: { aud: google_client_id }.to_json)

      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
        .to_return(status: 401, body: { error: "invalid_token" }.to_json)

      expect do
        described_class.fetch_user_info(access_token: access_token)
      end.to raise_error(StandardId::InvalidRequestError, "Failed to fetch Google user info: HTTP 401")
    end
  end

  describe ".verify_token" do
    let(:access_token) { "valid_access_token" }
    let(:expected_client_id) { google_client_id }
    let(:token_info) { { "aud" => expected_client_id, "sub" => "123456", "exp" => (Time.now + 3600).to_i } }

    it "verifies token with matching client_id" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: token_info.to_json)

      result = described_class.send(:verify_token, access_token)

      expect(result).to eq(token_info)
    end

    it "raises error when token verification fails" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 400, body: { error: "invalid_token" }.to_json)

      expect do
        described_class.send(:verify_token, access_token)
      end.to raise_error(StandardId::InvalidRequestError, "Invalid Google access token: invalid or expired")
    end

    it "raises error when audience mismatches" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: { aud: "wrong_client_id", sub: "123456" }.to_json)

      expect do
        described_class.send(:verify_token, access_token)
      end.to raise_error(StandardId::InvalidRequestError, "Invalid Google access token audience")
    end

    it "uses the same tokeninfo endpoint as ID token verification" do
      stub = stub_request(:post, described_class::TOKEN_INFO_ENDPOINT)
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: token_info.to_json)

      described_class.send(:verify_token, access_token)

      expect(stub).to have_been_requested
    end

    it "needs no client secret" do
      allow(StandardId.config).to receive(:google_client_secret).and_return(nil)
      stub_request(:post, described_class::TOKEN_INFO_ENDPOINT).to_return(status: 200, body: token_info.to_json)

      expect(described_class.send(:verify_token, access_token)).to eq(token_info)
    end
  end

  describe ".skip_csrf?" do
    it "is false: Google's web callback is a GET" do
      expect(described_class.skip_csrf?).to be(false)
    end
  end

  describe ".supports_mobile_callback?" do
    it "is false" do
      expect(described_class.supports_mobile_callback?).to be(false)
    end
  end

  describe ".flow_for" do
    it "is always :mobile, even for flow=web" do
      expect(described_class.flow_for({})).to eq(:mobile)
      expect(described_class.flow_for({ flow: "web" })).to eq(:mobile)
    end
  end

  describe ".resolve_params" do
    it "returns the params unchanged for either flow" do
      params = { id_token: "t" }

      expect(described_class.resolve_params(params, context: { flow: :mobile })).to eq(params)
      expect(described_class.resolve_params(params, context: { flow: :web })).to eq(params)
      expect(described_class.resolve_params(params)).to eq(params)
    end
  end

  describe "configuration" do
    let(:social) { StandardId.config.social }

    around do |example|
      names = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET]
      saved = ENV.to_h.slice(*names)
      names.each { |name| ENV.delete(name) }
      example.run
    ensure
      names.each { |name| ENV[name] = saved[name] }
      social.delete(:google_client_id)
      social.delete(:google_client_secret)
    end

    before do
      # Read the real configuration, not the stubs above.
      allow(StandardId.config).to receive(:google_client_id).and_call_original
      allow(StandardId.config).to receive(:google_client_secret).and_call_original
      social.delete(:google_client_id)
      social.delete(:google_client_secret)
      described_class.instance_variable_set(:@legacy_env_warned, nil)
    end

    it "requires the client secret" do
      expect(described_class.required_config_fields).to eq([:google_client_secret])
    end

    it "is enabled by google_client_id" do
      expect(described_class.enabling_config_field).to eq(:google_client_id)
      expect(described_class).not_to be_enabled

      social.google_client_id = "id"
      expect(described_class).to be_enabled
    end

    it "reports a missing secret by name while enabled" do
      social.google_client_id = "id"

      expect(described_class.configuration_errors).to eq(["google_client_secret is required when google_client_id is set"])
      social.google_client_secret = "secret"
      expect(described_class).to be_configured
    end

    it "reports nothing when disabled" do
      expect(described_class.configuration_errors).to be_empty
    end

    describe "ENV fallback" do
      it "reads the canonical upper-cased names" do
        ENV["GOOGLE_CLIENT_ID"] = "canonical-id"
        ENV["GOOGLE_CLIENT_SECRET"] = "canonical-secret"

        expect(StandardId.config.google_client_id).to eq("canonical-id")
        expect(StandardId.config.google_client_secret).to eq("canonical-secret")
      end

      it "falls back to the deprecated GOOGLE_OAUTH_* names, warning once per variable" do
        ENV["GOOGLE_OAUTH_CLIENT_ID"] = "legacy-id"
        ENV["GOOGLE_OAUTH_CLIENT_SECRET"] = "legacy-secret"
        allow(StandardId.deprecator).to receive(:warn)

        2.times do
          expect(StandardId.config.google_client_id).to eq("legacy-id")
          expect(StandardId.config.google_client_secret).to eq("legacy-secret")
        end
        expect(StandardId.deprecator).to have_received(:warn).with(/GOOGLE_OAUTH_CLIENT_ID is deprecated/).once
        expect(StandardId.deprecator).to have_received(:warn).with(/GOOGLE_OAUTH_CLIENT_SECRET is deprecated/).once
      end

      it "prefers the canonical name over the deprecated one" do
        ENV["GOOGLE_CLIENT_ID"] = "canonical-id"
        ENV["GOOGLE_OAUTH_CLIENT_ID"] = "legacy-id"

        expect(StandardId.config.google_client_id).to eq("canonical-id")
      end

      it "loses to explicit configuration, even nil" do
        ENV["GOOGLE_CLIENT_ID"] = "canonical-id"
        social.google_client_id = nil

        expect(StandardId.config.google_client_id).to be_nil
      end
    end
  end
end
