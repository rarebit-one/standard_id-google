# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardId::Google::StaffPolicy do
  let(:staff) { Struct.new(:staff).new(true) }
  let(:member) { Struct.new(:staff).new(false) }
  let(:predicate) { ->(account) { account.staff } }
  let(:policy) { StandardId::Google.staff_policy(staff_predicate: predicate) }
  let(:domains) { ["example.com"] }
  let(:require_for_staff) { true }

  before do
    allow(StandardId.config).to receive(:google_hosted_domains).and_return(domains)
    allow(StandardId.config).to receive(:google_require_for_staff).and_return(require_for_staff)
    allow(StandardId.config).to receive(:google_staff_predicate).and_return(nil)
  end

  def call(account, auth_method, provider, policy: self.policy)
    policy.call(account: account, auth_method: auth_method, provider: provider)
  end

  it "admits staff signing in with pinned Google" do
    expect(call(staff, :social, "google")).to be(true)
    expect(call(staff, :social, :google)).to be(true)
  end

  it "refuses staff on every other method" do
    [[:password, nil], [:passwordless, nil], [:remember_me, nil], [:unspecified, nil], [:social, "apple"], [nil, nil]].each do |method, provider|
      expect { call(staff, method, provider) }.to raise_error(StandardId::LoginMethodDenied, /Google Workspace/)
    end
  end

  it "refuses staff when only the provider name says google (not a social sign-in)" do
    expect { call(staff, :password, "google") }.to raise_error(StandardId::LoginMethodDenied)
    expect { call(staff, :remember_me, "google") }.to raise_error(StandardId::LoginMethodDenied)
  end

  it "refuses staff via a Google login while Google is not pinned" do
    allow(StandardId.config).to receive(:google_hosted_domains).and_return([])
    expect { call(staff, :social, "google") }.to raise_error(StandardId::LoginMethodDenied)
  end

  it "allows non-staff everything" do
    expect(call(member, :password, nil)).to be(true)
    expect(call(member, :social, "google")).to be(true)
    expect(call(nil, :password, nil)).to be(true)
  end

  it "fails closed without a staff predicate" do
    expect { call(staff, :social, "google", policy: StandardId::Google.staff_policy) }
      .to raise_error(StandardId::ConfigurationError, /staff_predicate/)
  end

  it "uses the configured predicate when none is given" do
    allow(StandardId.config).to receive(:google_staff_predicate).and_return(predicate)
    configured = StandardId::Google.staff_policy
    expect { call(staff, :password, nil, policy: configured) }.to raise_error(StandardId::LoginMethodDenied)
    expect(call(member, :password, nil, policy: configured)).to be(true)
  end

  it "propagates a predicate that raises (fails closed)" do
    boom = StandardId::Google.staff_policy(staff_predicate: ->(_) { raise "db down" })
    expect { call(staff, :social, "google", policy: boom) }.to raise_error("db down")
  end

  context "when google_require_for_staff is off" do
    let(:require_for_staff) { false }

    it "does not enforce" do
      expect(call(staff, :password, nil)).to be(true)
    end
  end

  describe "fallback" do
    let(:fallback) { ->(auth_method:, **) { auth_method != :passwordless } }
    let(:policy) { StandardId::Google.staff_policy(staff_predicate: predicate, fallback: fallback) }

    it "is consulted for non-staff only" do
      expect(call(member, :password, nil)).to be(true)
      expect(call(member, :passwordless, nil)).to be(false)
    end

    it "is never consulted for staff" do
      expect(call(staff, :social, "google")).to be(true)
    end
  end

  describe "StandardId::Google.any_of" do
    # Stands in for StandardId::VoidWhichBinds.staff_policy.
    let(:vwb) do
      lambda do |account:, auth_method:, provider:, **|
        next true unless account.staff
        raise StandardId::LoginMethodDenied, "vwb only" unless auth_method == :social && provider == "void_which_binds"

        true
      end
    end
    let(:combined) { StandardId::Google.any_of(policy, vwb) }

    it "admits staff by either method" do
      expect(call(staff, :social, "google", policy: combined)).to be(true)
      expect(call(staff, :social, "void_which_binds", policy: combined)).to be(true)
    end

    it "refuses staff by any other method, with the first refusal's message" do
      expect { call(staff, :password, nil, policy: combined) }
        .to raise_error(StandardId::LoginMethodDenied, /Google Workspace/)
    end

    it "treats a false return as a refusal and allows non-staff" do
      denying = StandardId::Google.any_of(->(**) { false })
      expect { call(member, :password, nil, policy: denying) }.to raise_error(StandardId::LoginMethodDenied)
      expect(call(member, :password, nil, policy: combined)).to be(true)
    end

    it "propagates errors other than a denial" do
      broken = StandardId::Google.any_of(StandardId::Google.staff_policy, vwb)
      expect { call(staff, :social, "void_which_binds", policy: broken) }.to raise_error(StandardId::ConfigurationError)
    end

    it "needs at least one policy" do
      expect { StandardId::Google.any_of }.to raise_error(ArgumentError)
    end
  end
end
