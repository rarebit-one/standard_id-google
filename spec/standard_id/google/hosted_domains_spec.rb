# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Google Workspace domain pinning" do
  subject(:provider) { StandardId::Providers::Google }

  let(:client_id) { "google_client_123" }
  let(:domains) { ["example.com"] }
  let(:id_token) { "an_id_token" }
  let(:claims) do
    {
      iss: "accounts.google.com", aud: client_id, sub: "123456789",
      email: "alice@example.com", email_verified: "true", hd: "example.com", name: "Alice"
    }
  end

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return(client_id)
    allow(StandardId.config).to receive(:google_client_secret).and_return("secret")
    allow(StandardId.config).to receive(:google_hosted_domains).and_return(domains)
  end

  def stub_tokeninfo(body = claims)
    stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
      .with(body: { id_token: id_token })
      .to_return(status: 200, body: body.to_json)
  end

  def refused(message = /Workspace|verified/)
    raise_error(StandardId::InvalidRequestError, message)
  end

  describe ".hosted_domains / .pinned?" do
    it "is empty and unpinned by default" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_call_original
      expect(provider.hosted_domains).to eq([])
      expect(provider).not_to be_pinned
    end

    it "normalises case, whitespace, blanks and duplicates" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return([" Example.COM ", "", nil, "example.com", "b.org"])
      expect(provider.hosted_domains).to eq(%w[example.com b.org])
    end

    it "accepts a comma or space separated String" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return("Example.com, b.org")
      expect(provider.hosted_domains).to eq(%w[example.com b.org])
    end

    it "is unpinned when only blanks are configured" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return([nil, " "])
      expect(provider).not_to be_pinned
    end
  end

  describe ".trusted_for_linking?" do
    it "is exactly true when pinned" do
      expect(provider.trusted_for_linking?).to be(true)
    end

    it "is false when unpinned (empty, nil or blank)" do
      [[], nil, [""]].each do |value|
        allow(StandardId.config).to receive(:google_hosted_domains).and_return(value)
        expect(provider.trusted_for_linking?).to be(false)
      end
    end
  end

  describe ".authorization_url" do
    def url(**opts)
      provider.authorization_url(state: "s", redirect_uri: "https://app.test/cb", **opts)
    end

    it "sends hd automatically for exactly one domain" do
      expect(url).to include("hd=example.com")
    end

    it "lets the caller override hd" do
      expect(url(hd: "other.com")).to include("hd=other.com")
      expect(url(hd: "other.com")).not_to include("hd=example.com")
    end

    it "sends no hd for several domains" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return(%w[a.com b.com])
      expect(url).not_to include("hd=")
    end

    it "sends no hd when unpinned" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return([])
      expect(url).not_to include("hd=")
    end
  end

  describe "id_token flow (mobile / API)" do
    it "admits a verified Workspace login and returns hd" do
      stub_tokeninfo
      result = provider.get_user_info(id_token: id_token)
      expect(result[:user_info]).to include("email" => "alice@example.com", "hd" => "example.com")
    end

    it "matches hd and the email domain case-insensitively" do
      stub_tokeninfo(claims.merge(hd: "Example.COM", email: "Alice@EXAMPLE.com"))
      expect(provider.get_user_info(id_token: id_token)[:user_info]["sub"]).to eq("123456789")
    end

    it "accepts a boolean email_verified" do
      stub_tokeninfo(claims.merge(email_verified: true))
      expect(provider.verify_id_token(id_token: id_token)["sub"]).to eq("123456789")
    end

    it "accepts any of several configured domains" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return(%w[a.com example.com])
      stub_tokeninfo
      expect(provider.verify_id_token(id_token: id_token)["hd"]).to eq("example.com")
    end

    it "refuses consumer gmail (no hd)" do
      stub_tokeninfo(claims.except(:hd).merge(email: "alice@gmail.com"))
      expect { provider.get_user_info(id_token: id_token) }.to refused(/allowed Workspace domain/)
    end

    it "refuses a blank hd" do
      stub_tokeninfo(claims.merge(hd: ""))
      expect { provider.get_user_info(id_token: id_token) }.to refused(/allowed Workspace domain/)
    end

    it "refuses a non-string hd" do
      stub_tokeninfo(claims.merge(hd: ["example.com"]))
      expect { provider.get_user_info(id_token: id_token) }.to refused(/allowed Workspace domain/)
    end

    it "refuses a different hd" do
      stub_tokeninfo(claims.merge(hd: "evil.com", email: "alice@evil.com"))
      expect { provider.get_user_info(id_token: id_token) }.to refused(/allowed Workspace domain/)
    end

    it "refuses a lookalike or subdomain hd (exact match only)" do
      %w[example.com.evil.com sub.example.com notexample.com].each do |hd|
        stub_tokeninfo(claims.merge(hd: hd, email: "alice@#{hd}"))
        expect { provider.verify_id_token(id_token: id_token) }.to refused(/allowed Workspace domain/)
      end
    end

    it "refuses an email on another domain than hd" do
      stub_tokeninfo(claims.merge(email: "alice@gmail.com"))
      expect { provider.get_user_info(id_token: id_token) }.to refused(/not on its Workspace domain/)
    end

    it "refuses a subdomain or lookalike email under the right hd" do
      ["alice@sub.example.com", "alice@example.com.evil.com", "alice@@example.com", "example.com", "@example.com", nil].each do |email|
        stub_tokeninfo(claims.merge(email: email))
        expect { provider.verify_id_token(id_token: id_token) }.to refused(/not on its Workspace domain/)
      end
    end

    it "refuses an unverified email" do
      [false, "false", nil, "TRUE"].each do |value|
        stub_tokeninfo(claims.merge(email_verified: value))
        expect { provider.get_user_info(id_token: id_token) }.to refused(/not verified/)
      end
    end

    it "refuses an access-token-only sign-in (no ID token to pin on)" do
      expect(StandardId::HttpClient).not_to receive(:get_with_bearer)
      expect { provider.get_user_info(access_token: "at") }.to refused(/access-token sign-in is not available/)
    end

    it "does not pin when unconfigured (consumer gmail still works)" do
      allow(StandardId.config).to receive(:google_hosted_domains).and_return([])
      stub_tokeninfo(claims.except(:hd).merge(email: "alice@gmail.com", email_verified: "false"))
      expect(provider.get_user_info(id_token: id_token)[:user_info]["email"]).to eq("alice@gmail.com")
    end
  end

  describe "web code flow" do
    let(:code) { "auth_code" }
    let(:redirect_uri) { "https://app.test/cb" }
    let(:userinfo) { { id: "123456789", email: "alice@example.com", verified_email: true, name: "Alice" } }
    let(:token_body) { { access_token: "at", id_token: id_token, token_type: "Bearer" } }

    def stub_web(token_body: self.token_body, userinfo: self.userinfo, access_sub: "123456789")
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: token_body.to_json)
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { access_token: "at" })
        .to_return(status: 200, body: { aud: client_id, sub: access_sub }.to_json)
      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo").to_return(status: 200, body: userinfo.to_json)
    end

    def exchange(**opts)
      provider.get_user_info(code: code, redirect_uri: redirect_uri, **opts)
    end

    it "admits a verified Workspace login, with identity taken from the ID token" do
      stub_tokeninfo
      stub_web
      info = exchange(nonce: nil)[:user_info]
      expect(info).to include("sub" => "123456789", "email" => "alice@example.com", "email_verified" => "true", "hd" => "example.com")
    end

    it "refuses when the token response has no id_token, even though userinfo looks fine" do
      stub_web(token_body: { access_token: "at" })
      expect { exchange }.to refused(/missing id_token/)
    end

    it "refuses consumer gmail (no hd)" do
      stub_tokeninfo(claims.except(:hd).merge(email: "alice@gmail.com"))
      stub_web(userinfo: userinfo.merge(email: "alice@gmail.com"))
      expect { exchange }.to refused(/allowed Workspace domain/)
    end

    it "refuses a wrong hd" do
      stub_tokeninfo(claims.merge(hd: "evil.com", email: "alice@evil.com"))
      stub_web
      expect { exchange }.to refused(/allowed Workspace domain/)
    end

    it "refuses an email domain different from hd" do
      stub_tokeninfo(claims.merge(email: "alice@gmail.com"))
      stub_web
      expect { exchange }.to refused(/not on its Workspace domain/)
    end

    it "refuses an unverified email" do
      stub_tokeninfo(claims.merge(email_verified: "false"))
      stub_web
      expect { exchange }.to refused(/not verified/)
    end

    it "refuses when userinfo names a different subject than the ID token" do
      stub_tokeninfo
      stub_web(userinfo: userinfo.merge(id: "999"), access_sub: "999")
      expect { exchange }.to refused(/does not match the ID token/)
    end

    it "does not trust a userinfo email that disagrees with the ID token" do
      stub_tokeninfo
      stub_web(userinfo: userinfo.merge(email: "mallory@evil.com"))
      expect(exchange[:user_info]["email"]).to eq("alice@example.com")
    end

    it "still checks the nonce on the ID token" do
      stub_tokeninfo(claims.merge(nonce: "other"))
      stub_web
      expect { exchange(nonce: "expected") }.to raise_error(StandardId::InvalidRequestError, /nonce/)
    end
  end
end
