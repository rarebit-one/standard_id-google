require "json"
require "jwt"
require "net/http"
require "openssl"

module StandardId
  module Providers
    class Google < Base
      AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth".freeze
      TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token".freeze
      USERINFO_ENDPOINT = "https://www.googleapis.com/oauth2/v2/userinfo".freeze
      # Google's documented tokeninfo endpoint, for both ID tokens and access
      # tokens (developers.google.com/identity/sign-in/web/backend-auth,
      # developers.google.com/identity/protocols/oauth2). The legacy
      # www.googleapis.com/oauth2/v3/tokeninfo host is no longer used.
      TOKEN_INFO_ENDPOINT = "https://oauth2.googleapis.com/tokeninfo".freeze
      # Google's JWKS endpoint for local ID token signature verification.
      JWKS_URI = "https://www.googleapis.com/oauth2/v3/certs".freeze
      VALID_ISSUERS = ["accounts.google.com", "https://accounts.google.com"].freeze
      DEFAULT_SCOPE = "openid email profile".freeze
      AUTHORIZATION_PARAM_DEFAULTS = {
        scope: DEFAULT_SCOPE
      }.freeze

      # Google's signing keys rotate rarely; an unknown `kid` forces an early
      # refetch (see #fetch_jwk), so a long TTL costs nothing on rotation.
      JWKS_CACHE_TTL = 3600
      # Floor between forced refetches, so a stream of ID tokens carrying
      # made-up `kid`s cannot turn this process into a request amplifier
      # against Google.
      JWKS_MIN_REFRESH_INTERVAL = 60
      # Accepted clock drift for exp/iat, matching the sibling Apple provider.
      CLOCK_SKEW_SECONDS = 60

      # Pre-0.5.0 install generators wired the fields to these variables.
      # Still read, with a deprecation warning, when the canonical variable
      # (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET) is unset and the host never
      # assigns the field.
      LEGACY_ENV = {
        google_client_id: "GOOGLE_OAUTH_CLIENT_ID",
        google_client_secret: "GOOGLE_OAUTH_CLIENT_SECRET"
      }.freeze

      @jwks_mutex = Mutex.new
      @jwks_cache = nil

      class << self
        def provider_name
          "google"
        end

        # The Google Workspace domains sign-in is pinned to
        # (`social.google_hosted_domains`): lowercase, stripped, de-duplicated.
        # Empty means the provider is not pinned and behaves as it always has.
        def hosted_domains
          raw = StandardId.config.google_hosted_domains
          list = raw.is_a?(String) ? raw.split(/[\s,]+/) : Array(raw)
          list.map { |domain| domain.to_s.strip.downcase }.reject(&:empty?).uniq
        end

        def pinned?
          hosted_domains.any?
        end

        # True ONLY while sign-in is pinned to Workspace domains. Core calls
        # this on the class, after get_user_info has returned for the very
        # login being linked, so there is no per-login question to answer:
        # while pinned, every login that gets that far presented a verified
        # ID token whose `hd` is one of the configured domains and whose
        # email is on that domain (see enforce_hosted_domain!), so the
        # address is one the domain's Workspace admin provisioned. Unpinned,
        # Google is a public IdP and must never be trusted for linking.
        def trusted_for_linking?
          pinned?
        end

        def supported_authorization_params
          [:nonce, :login_hint, :prompt, :scope, :access_type, :hd, :response_mode, :include_granted_scopes]
        end

        def authorization_url(state:, redirect_uri:, **options)
          # With exactly one pinned domain, `hd` is sent as Google's account
          # chooser hint (a caller-supplied `hd` still wins). It is only a
          # hint: pinning is enforced on the verified ID token, never on it.
          defaults = AUTHORIZATION_PARAM_DEFAULTS
          domains = hosted_domains
          defaults = defaults.merge(hd: domains.first) if domains.one?

          build_authorization_url(
            endpoint: AUTH_ENDPOINT,
            client_id: credentials[:client_id],
            redirect_uri:, state:, options:,
            defaults: defaults
          )
        end

        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, nonce: nil, **_options)
          if id_token.present?
            build_response(
              verify_id_token(id_token: id_token, nonce: nonce),
              tokens: { id_token: id_token }
            )
          elsif access_token.present?
            # An access token carries no ID token, so there is no verified
            # `hd` claim to pin on: refused rather than trusted.
            if pinned?
              raise StandardId::InvalidRequestError,
                    "Google access-token sign-in is not available while google_hosted_domains is set"
            end

            build_response(
              fetch_user_info(access_token: access_token),
              tokens: { access_token: access_token }
            )
          elsif code.present?
            exchange_code_for_user_info(code: code, redirect_uri: redirect_uri, nonce: nonce)
          else
            raise StandardId::InvalidRequestError, "Google sign-in requires a code, an id_token or an access_token"
          end
        end

        # `google_client_id` switches the provider on (it is the enabling
        # field). `google_client_secret` is required while it is set: an
        # enabled provider shows the web sign-in button, and the web flow's
        # code exchange needs the secret — without it the user authenticates
        # with Google and only then does the callback fail. The native
        # id_token and access_token flows verify through Google's JWKS (or
        # tokeninfo) and need only the client ID.
        #
        # ENV fallbacks (standard_id >= 0.42): GOOGLE_CLIENT_ID and
        # GOOGLE_CLIENT_SECRET; the pre-0.5.0 GOOGLE_OAUTH_* names are read as
        # a deprecated fallback.
        def config_schema
          {
            google_client_id: { type: :string, default: -> { legacy_env(:google_client_id) } },
            google_client_secret: { type: :string, default: -> { legacy_env(:google_client_secret) }, required: true },
            # Workspace domains sign-in is pinned to; empty (default) = not pinned.
            google_hosted_domains: { type: :any, default: -> { [] }, env: false },
            # StandardId::Google.staff_policy settings.
            google_require_for_staff: { type: :boolean, default: true },
            google_staff_predicate: { type: :any, default: nil, env: false },
            # ID token verification mode:
            #   :jwks (default) — verify the signature locally against Google's
            #     JWKS at #{JWKS_URI}. More reliable (no network round-trip for
            #     every auth) and keeps the token within the process.
            #   :tokeninfo — POST the raw token to Google's tokeninfo endpoint
            #     (legacy behaviour, pre-0.8.0). Kept for one release as an
            #     explicit opt-in. Will be removed in 0.9.0.
            google_id_token_verification: { type: :string, default: "jwks", env: false }
          }
        end

        def default_scope
          DEFAULT_SCOPE
        end

        def exchange_code_for_user_info(code:, redirect_uri:, nonce: nil)
          rescue_to_oauth_error do
            raise StandardId::InvalidRequestError, "Google authorization code is missing" if code.blank?

            creds = credentials
            if creds[:client_secret].blank?
              raise StandardId::InvalidRequestError, "Google OAuth credentials are incomplete: google_client_secret not set"
            end

            token_response = HttpClient.post_form(TOKEN_ENDPOINT, {
              client_id: creds[:client_id],
              client_secret: creds[:client_secret],
              code: code,
              grant_type: "authorization_code",
              redirect_uri: redirect_uri
            }.compact)

            unless token_response.is_a?(Net::HTTPSuccess)
              raise StandardId::InvalidRequestError,
                    "Failed to exchange Google authorization code: #{error_reason(token_response)}"
            end

            parsed_token = JSON.parse(token_response.body)
            access_token = parsed_token["access_token"]
            raise StandardId::InvalidRequestError, "Google token response is missing access_token" if access_token.blank?

            if pinned?
              # Pinned: the ID token is required and decides identity; the
              # userinfo only adds profile fields.
              if parsed_token["id_token"].blank?
                raise StandardId::InvalidRequestError, "Google token response is missing id_token"
              end

              id_claims = verify_id_token(id_token: parsed_token["id_token"], nonce: nonce)
              user_info = pinned_user_info(fetch_user_info(access_token: access_token), id_claims)
              return build_response(user_info, tokens: extract_tokens(parsed_token))
            end

            # Web flow with a server-generated nonce: check it on the ID token.
            if parsed_token["id_token"].present? && nonce.present?
              verify_id_token(id_token: parsed_token["id_token"], nonce: nonce)
            end

            build_response(fetch_user_info(access_token: access_token), tokens: extract_tokens(parsed_token))
          end
        end

        # Verifies a Google ID token and returns its claims.
        #
        # Default mode (:jwks): verifies the signature locally against
        # Google's JWKS, keeping the token within the process. Signature,
        # algorithm (RS256 only), expiry, issuer and audience are all checked
        # here; no network call is required after the keys are cached.
        #
        # Fallback mode (:tokeninfo): POSTs the raw token to Google's
        # tokeninfo endpoint, which checks signature + expiry server-side;
        # audience, issuer and nonce are checked here. Kept for one release as
        # config.google_id_token_verification = :tokeninfo. Will be removed in
        # 0.9.0.
        def verify_id_token(id_token:, nonce: nil)
          rescue_to_oauth_error do
            raise StandardId::InvalidRequestError, "Google id_token is missing" if id_token.blank?

            if tokeninfo_verification?
              verify_id_token_via_tokeninfo(id_token: id_token, nonce: nonce)
            else
              verify_id_token_via_jwks(id_token: id_token, nonce: nonce)
            end
          end
        end

        def fetch_user_info(access_token:)
          rescue_to_oauth_error do
            raise StandardId::InvalidRequestError, "Google access token is missing" if access_token.blank?

            token_info = verify_token(access_token)
            user_response = HttpClient.get_with_bearer(USERINFO_ENDPOINT, access_token)

            unless user_response.is_a?(Net::HTTPSuccess)
              raise StandardId::InvalidRequestError, "Failed to fetch Google user info: HTTP #{user_response.code}"
            end

            with_oidc_claims(JSON.parse(user_response.body), token_info)
          end
        end

        # Drop the in-process JWKS cache (tests, or after a known rotation).
        def reset_jwks_cache!
          @jwks_mutex.synchronize { @jwks_cache = nil }
        end

        private

        # True when the host has opted into the :tokeninfo fallback.
        def tokeninfo_verification?
          StandardId.config.google_id_token_verification.to_s == "tokeninfo"
        end

        # Local JWKS-based verification. RS256 only. The token never leaves
        # the process after the keys are cached.
        def verify_id_token_via_jwks(id_token:, nonce: nil)
          _unverified_payload, header = JWT.decode(id_token, nil, false)
          kid = header["kid"]
          raise StandardId::InvalidRequestError, "Invalid Google ID token: header has no kid" if kid.blank?

          jwk = fetch_jwk(kid: kid)
          creds = credentials

          # RS256 is the only algorithm Google uses for ID tokens. Enforcing
          # it here blocks alg:none and alg:HS256 attacks even if the JWKS
          # call is somehow poisoned.
          verified_payload, = JWT.decode(
            id_token,
            jwk.public_key,
            true,
            algorithms: ["RS256"],
            verify_expiration: true,
            leeway: CLOCK_SKEW_SECONDS
          )

          # Issuer and audience are checked manually for robustness across
          # JWT gem minor versions and to keep error messages consistent.
          unless VALID_ISSUERS.include?(verified_payload["iss"])
            raise StandardId::InvalidRequestError, "Invalid Google ID token issuer"
          end

          # Support the multiple-client-id case: if the config carries an
          # array, any member may match.
          allowed = Array(creds[:client_id])
          unless allowed.include?(verified_payload["aud"])
            raise StandardId::InvalidRequestError, "Invalid Google ID token audience"
          end

          # Constant-time, and the error never echoes either value.
          verify_nonce!(expected: nonce, actual: verified_payload["nonce"])

          enforce_hosted_domain!(verified_payload) if pinned?

          extract_id_token_claims(verified_payload)
        rescue JWT::DecodeError => e
          raise StandardId::InvalidRequestError, "Invalid Google ID token: #{e.message}"
        end

        # Legacy tokeninfo path. Kept as an explicit opt-in for one release.
        # Deprecated: will be removed in 0.9.0.
        def verify_id_token_via_tokeninfo(id_token:, nonce: nil)
          response = HttpClient.post_form(TOKEN_INFO_ENDPOINT, id_token: id_token)
          raise StandardId::InvalidRequestError, "Invalid Google ID token: invalid or expired" unless response.is_a?(Net::HTTPSuccess)

          token_info = JSON.parse(response.body)

          unless token_info["aud"].present? && token_info["aud"] == credentials[:client_id]
            raise StandardId::InvalidRequestError, "Invalid Google ID token audience"
          end

          unless VALID_ISSUERS.include?(token_info["iss"])
            raise StandardId::InvalidRequestError, "Invalid Google ID token issuer"
          end

          # Constant-time, and the error never echoes either value.
          verify_nonce!(expected: nonce, actual: token_info["nonce"])

          enforce_hosted_domain!(token_info) if pinned?

          extract_id_token_claims(token_info)
        end

        # Pull the canonical set of ID token claims from a verified payload.
        def extract_id_token_claims(claims)
          {
            "hd" => claims["hd"],
            "sub" => claims["sub"],
            "email" => claims["email"],
            "email_verified" => claims["email_verified"],
            "name" => claims["name"],
            "given_name" => claims["given_name"],
            "family_name" => claims["family_name"],
            "picture" => claims["picture"],
            "locale" => claims["locale"]
          }.compact
        end

        # Look `kid` up in Google's JWKS, served from an in-process cache
        # (JWKS_CACHE_TTL). An unknown `kid` refetches once — Google may have
        # rotated — subject to JWKS_MIN_REFRESH_INTERVAL.
        def fetch_jwk(kid:)
          jwk_data = find_jwk(jwks_keys, kid) || find_jwk(jwks_keys(refresh: true), kid)
          raise StandardId::InvalidRequestError, "Invalid Google ID token: signing key not found in Google's JWKS" unless jwk_data

          JWT::JWK.import(jwk_data)
        end

        def find_jwk(keys, kid)
          keys.find { |key| key["kid"] == kid }
        end

        def jwks_keys(refresh: false)
          @jwks_mutex.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            cache = @jwks_cache

            stale = cache.nil? || now - cache[:fetched_at] > JWKS_CACHE_TTL
            forced = refresh && cache && now - cache[:fetched_at] >= JWKS_MIN_REFRESH_INTERVAL
            if stale || forced
              @jwks_cache = cache = { keys: download_jwks, fetched_at: now }
            end

            cache[:keys]
          end
        end

        # Fetched through StandardId::HttpClient's connection setup, so the
        # request gets its timeouts and its private/internal-address guard.
        # HttpClient has no public plain GET (only get_with_bearer, which would
        # send an empty Authorization header), hence the two private calls.
        def download_jwks
          rescue_to_oauth_error("Failed to fetch Google JWKS") do
            uri, resolved_ip = HttpClient.send(:validate_url!, JWKS_URI)
            response = HttpClient.send(:start_connection, uri, resolved_ip: resolved_ip) do |http|
              http.request(Net::HTTP::Get.new(uri))
            end
            raise StandardId::OAuthError, "Failed to fetch Google JWKS: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

            keys = JSON.parse(response.body)["keys"]
            raise StandardId::OAuthError, "Failed to fetch Google JWKS: response has no keys" unless keys.is_a?(Array)

            keys
          end
        end

        # Pins sign-in to the configured Workspace domains, on the claims of
        # a verified ID token: `hd` must be one of them (an exact,
        # case-insensitive match; consumer accounts have no `hd`), the email
        # must be verified, and its domain must equal `hd`. Messages never
        # echo the claims.
        def enforce_hosted_domain!(claims)
          hd = claims["hd"]
          hd = hd.is_a?(String) ? hd.strip.downcase : nil
          unless hd.present? && hosted_domains.include?(hd)
            raise StandardId::InvalidRequestError, "Google account is not in an allowed Workspace domain"
          end

          unless [true, "true"].include?(claims["email_verified"])
            raise StandardId::InvalidRequestError, "Google account email is not verified"
          end

          email = claims["email"]
          local, separator, domain = email.is_a?(String) ? email.strip.rpartition("@") : []
          unless separator == "@" && local.present? && !local.include?("@") && domain.downcase == hd
            raise StandardId::InvalidRequestError, "Google account email is not on its Workspace domain"
          end
        end

        # Web flow, pinned: identity comes from the verified ID token. The
        # userinfo must agree on the subject, and its profile fields are kept.
        def pinned_user_info(userinfo, id_claims)
          unless userinfo.is_a?(Hash) && userinfo["sub"].to_s == id_claims["sub"].to_s && id_claims["sub"].present?
            raise StandardId::InvalidRequestError, "Google user info does not match the ID token"
          end

          userinfo.merge(id_claims.slice("sub", "email", "email_verified", "hd"))
        end

        # The client ID every flow needs, and the secret only the code
        # exchange needs (checked there). Raises when the provider is off.
        def credentials
          client_id = StandardId.config.google_client_id
          raise StandardId::InvalidRequestError, "Google OAuth is not configured" if client_id.blank?

          {
            client_id: client_id,
            client_secret: StandardId.config.google_client_secret
          }
        end

        # Confirms an access token was issued to this app's client before its
        # userinfo is trusted.
        def verify_token(access_token)
          response = HttpClient.post_form(TOKEN_INFO_ENDPOINT, access_token: access_token)
          raise StandardId::InvalidRequestError, "Invalid Google access token: invalid or expired" unless response.is_a?(Net::HTTPSuccess)

          token_info = JSON.parse(response.body)

          unless token_info["aud"].present? && token_info["aud"] == credentials[:client_id]
            raise StandardId::InvalidRequestError, "Invalid Google access token audience"
          end

          token_info
        end

        # The v2 userinfo endpoint names the subject `id` and the verified
        # flag `verified_email`. standard_id (>= 0.44) matches returning
        # logins on the OIDC `sub` and links existing accounts only on
        # `email_verified`, so add both claims; the original keys are kept.
        # The subject must agree with the one tokeninfo reported for the
        # access token, when it reported one.
        def with_oidc_claims(user_info, token_info)
          return user_info unless user_info.is_a?(Hash)

          claims = user_info.dup
          claims["sub"] = claims["id"].to_s.presence if claims["sub"].blank?
          claims["email_verified"] = claims["verified_email"] if !claims.key?("email_verified") && claims.key?("verified_email")
          claims.compact!

          token_sub = token_info.is_a?(Hash) ? token_info["sub"].to_s.presence : nil
          if token_sub && claims["sub"] && token_sub != claims["sub"].to_s
            raise StandardId::InvalidRequestError, "Google user info does not match the access token"
          end

          claims
        end

        def error_reason(response)
          body = JSON.parse(response.body.to_s)
          reason = body["error"] if body.is_a?(Hash)
          reason.presence || "HTTP #{response.code}"
        rescue JSON::ParserError
          "HTTP #{response.code}"
        end

        def legacy_env(field)
          name = LEGACY_ENV.fetch(field)
          value = ENV[name]
          return nil if value.blank?

          # An unassigned field's default is re-evaluated on read; warn once.
          @legacy_env_warned ||= {}
          return value if @legacy_env_warned[name]

          @legacy_env_warned[name] = true
          StandardId.deprecator.warn(
            "standard_id-google: reading #{field} from #{name} is deprecated. " \
            "Rename the variable to #{field.to_s.upcase} (or assign config.social.#{field} explicitly)."
          )
          value
        end
      end
    end
  end
end
