require "json"
require "net/http"

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
      VALID_ISSUERS = ["accounts.google.com", "https://accounts.google.com"].freeze
      DEFAULT_SCOPE = "openid email profile".freeze
      AUTHORIZATION_PARAM_DEFAULTS = {
        scope: DEFAULT_SCOPE
      }.freeze

      # Pre-0.5.0 install generators wired the fields to these variables.
      # Still read, with a deprecation warning, when the canonical variable
      # (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET) is unset and the host never
      # assigns the field.
      LEGACY_ENV = {
        google_client_id: "GOOGLE_OAUTH_CLIENT_ID",
        google_client_secret: "GOOGLE_OAUTH_CLIENT_SECRET"
      }.freeze

      class << self
        def provider_name
          "google"
        end

        def supported_authorization_params
          [:nonce, :login_hint, :prompt, :scope, :access_type, :hd, :response_mode, :include_granted_scopes]
        end

        def authorization_url(state:, redirect_uri:, **options)
          build_authorization_url(
            endpoint: AUTH_ENDPOINT,
            client_id: credentials[:client_id],
            redirect_uri:, state:, options:,
            defaults: AUTHORIZATION_PARAM_DEFAULTS
          )
        end

        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, nonce: nil, **_options)
          if id_token.present?
            build_response(
              verify_id_token(id_token: id_token, nonce: nonce),
              tokens: { id_token: id_token }
            )
          elsif access_token.present?
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
        # id_token and access_token flows verify through Google's tokeninfo
        # endpoint and need only the client ID.
        #
        # ENV fallbacks (standard_id >= 0.42): GOOGLE_CLIENT_ID and
        # GOOGLE_CLIENT_SECRET; the pre-0.5.0 GOOGLE_OAUTH_* names are read as
        # a deprecated fallback.
        def config_schema
          {
            google_client_id: { type: :string, default: -> { legacy_env(:google_client_id) } },
            google_client_secret: { type: :string, default: -> { legacy_env(:google_client_secret) }, required: true }
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

            # Web flow with a server-generated nonce: check it on the ID token.
            if parsed_token["id_token"].present? && nonce.present?
              verify_id_token(id_token: parsed_token["id_token"], nonce: nonce)
            end

            build_response(fetch_user_info(access_token: access_token), tokens: extract_tokens(parsed_token))
          end
        end

        # Verifies through Google's tokeninfo endpoint, which checks the
        # signature and expiry; the audience, issuer and nonce are checked
        # here. Needs only the client ID.
        def verify_id_token(id_token:, nonce: nil)
          rescue_to_oauth_error do
            raise StandardId::InvalidRequestError, "Google id_token is missing" if id_token.blank?

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

            {
              "sub" => token_info["sub"],
              "email" => token_info["email"],
              "email_verified" => token_info["email_verified"],
              "name" => token_info["name"],
              "given_name" => token_info["given_name"],
              "family_name" => token_info["family_name"],
              "picture" => token_info["picture"],
              "locale" => token_info["locale"]
            }.compact
          end
        end

        def fetch_user_info(access_token:)
          rescue_to_oauth_error do
            raise StandardId::InvalidRequestError, "Google access token is missing" if access_token.blank?

            verify_token(access_token)
            user_response = HttpClient.get_with_bearer(USERINFO_ENDPOINT, access_token)

            unless user_response.is_a?(Net::HTTPSuccess)
              raise StandardId::InvalidRequestError, "Failed to fetch Google user info: HTTP #{user_response.code}"
            end

            JSON.parse(user_response.body)
          end
        end

        private

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
