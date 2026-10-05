# frozen_string_literal: true

module StandardId
  module Google
    # A `login_method_policy` (standard_id >= 0.45) that refuses every way into
    # a staff account except a Google sign-in pinned to the organisation's
    # Workspace domain(s), so removing someone from the Workspace removes their
    # way into the app:
    #
    #   StandardId.configure do |c|
    #     c.social.google_hosted_domains = ["example.com"]
    #     c.login_method_policy = StandardId::Google.staff_policy(
    #       staff_predicate: ->(account) { account.staff? }
    #     )
    #   end
    #
    # standard_id consults it before any session or token exists, in every flow
    # (web password, passwordless, remember-me, other social providers, the
    # OAuth grants, and each refresh with the original sign-in's method).
    # Remember-me re-authentication is therefore refused for staff, exactly as
    # the void_which_binds policy does: staff sign in again with Google.
    # Non-staff accounts pass through to `fallback`, if given (another policy
    # with the same keyword contract), and are otherwise allowed.
    #
    # Enforced while `social.google_require_for_staff` is true (the default).
    # `staff_predicate` falls back to `social.google_staff_predicate`; with
    # neither, every decision fails closed (raises). A staff Google login is
    # admitted only while `google_hosted_domains` is non-empty: an unpinned
    # Google sign-in proves nothing about the organisation, so it is refused.
    class StaffPolicy
      MESSAGE = "Staff accounts must sign in with the organisation's Google Workspace account"

      attr_reader :staff_predicate

      def initialize(staff_predicate: nil, fallback: nil)
        @staff_predicate = staff_predicate
        @fallback = fallback
      end

      def call(account:, auth_method:, provider:, request: nil, flow: nil)
        if require_for_staff? && staff?(account)
          raise StandardId::LoginMethodDenied, MESSAGE unless pinned_google?(auth_method, provider)

          return true
        end
        return true if @fallback.nil?

        context = { account:, auth_method:, provider:, request:, flow: }
        @fallback.call(**StandardId::Utils::CallableParameterFilter.filter(@fallback, context))
      end

      def staff?(account)
        predicate = @staff_predicate || StandardId.config.google_staff_predicate
        unless predicate.respond_to?(:call)
          raise StandardId::ConfigurationError, "StandardId::Google.staff_policy needs a staff_predicate (or social.google_staff_predicate)"
        end

        account.present? && predicate.call(account) ? true : false
      end

      private

      def require_for_staff?
        StandardId.config.google_require_for_staff == true
      end

      def pinned_google?(auth_method, provider)
        auth_method&.to_sym == :social &&
          provider.to_s == StandardId::Providers::Google.provider_name &&
          StandardId::Providers::Google.pinned?
      end
    end

    # Combines login_method_policies for a host that runs more than one staff
    # policy (for example this one and StandardId::VoidWhichBinds.staff_policy).
    # Each of those admits a staff account by ITS method and refuses the rest,
    # so chaining them with `fallback:` would lock staff out of the other's
    # method. any_of admits when ANY policy allows, and refuses (with the first
    # refusal's message) only when all do. Non-staff pass every such policy.
    # A policy that raises anything but LoginMethodDenied (a missing predicate,
    # a bug) propagates: the request fails closed.
    class AnyOfPolicy
      def initialize(policies)
        @policies = policies
        raise ArgumentError, "any_of needs at least one policy" if @policies.empty?
      end

      def call(**context)
        denial = nil
        @policies.each do |policy|
          allowed = policy.call(**StandardId::Utils::CallableParameterFilter.filter(policy, context))
          return true if allowed
          denial ||= StandardId::LoginMethodDenied.new
        rescue StandardId::LoginMethodDenied => e
          denial ||= e
        end
        raise denial
      end
    end

    def self.staff_policy(staff_predicate: nil, fallback: nil)
      StaffPolicy.new(staff_predicate: staff_predicate, fallback: fallback)
    end

    def self.any_of(*policies)
      AnyOfPolicy.new(policies.flatten)
    end
  end
end
