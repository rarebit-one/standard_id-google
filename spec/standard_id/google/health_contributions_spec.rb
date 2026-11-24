# frozen_string_literal: true

require "spec_helper"

# standard_health is not in this bundle, so the hook is exercised the way
# standard_health fires it: run_load_hooks(:standard_health, registry). The
# fake records calls through the only methods the real registry exposes (so
# the hook calling anything else fails with NoMethodError) and keeps each
# entry's options, `if:` predicate included, for the examples to evaluate.
RSpec.describe "standard_id-google's standard_health load hook" do
  let(:env_spec_dsl) do
    Class.new do
      attr_reader :entries

      def initialize
        @entries = []
      end

      def required(name, **options) = @entries << [:required, name, options]
      def recommended(name, **options) = @entries << [:recommended, name, options]
      def forbidden(name, **options) = @entries << [:forbidden, name, options]
    end
  end

  let(:registry) do
    dsl_class = env_spec_dsl
    Class.new do
      attr_reader :env_vars

      define_method(:initialize) do
        @env_vars = {}
        @dsl_class = dsl_class
      end

      # standard_id's own hook contributes a check; accept it.
      def contribute_check(*, **); end

      def contribute_env_vars(contributor, &block)
        @env_vars[contributor] = @dsl_class.new.tap { |dsl| dsl.instance_eval(&block) }.entries
      end
    end.new
  end

  let(:social) { StandardId.config.social }
  let(:entries) { registry.env_vars.fetch("standard_id-google") }

  def entry(name) = entries.find { |_, entry_name, _| entry_name == name }

  def applies?(name)
    predicate = entry(name)[2][:if]
    predicate.nil? || predicate.call
  end

  context "without standard_health" do
    it "registers the hook without loading or needing standard_health, and runs nothing" do
      expect(defined?(StandardHealth)).to be_nil
      expect(ActiveSupport.instance_variable_get(:@load_hooks)[:standard_health]).not_to be_empty
      expect(ActiveSupport.instance_variable_get(:@loaded)[:standard_health]).to be_blank
      expect(Gem.loaded_specs["standard_id-google"].runtime_dependencies.map(&:name)).not_to include("standard_health")
    end
  end

  context "when standard_health fires its load hooks" do
    before { ActiveSupport.run_load_hooks(:standard_health, registry) }

    # run_load_hooks remembers its base so later on_load calls fire on it; drop
    # the fake so it cannot reach another example. Forget any field an example
    # assigned, so reads fall back to the schema default again.
    after do
      ActiveSupport.instance_variable_get(:@loaded)[:standard_health]&.delete(registry)
      %i[google_client_id google_client_secret google_require_for_staff].each { |field| social.delete(field) }
    end

    it "declares every env var the plugin reads, under its own contributor" do
      expect(entries.map { |level, name, _| [level, name] }).to eq(
        [%i[recommended GOOGLE_CLIENT_ID], %i[required GOOGLE_CLIENT_SECRET], %i[forbidden GOOGLE_REQUIRE_FOR_STAFF]]
      )
    end

    it "covers every config field that falls back to ENV" do
      env_names = StandardId::Providers::Google.config_schema.filter_map do |field, options|
        StandardId::ProviderRegistry.env_var_for(field, options)
      end

      expect(entries.map { |_, name, _| name.to_s }).to match_array(env_names)
    end

    it "describes every env var" do
      expect(entries.map { |_, _, options| options[:description] }).to all(be_present)
    end

    it "uses plain environment names only" do
      expect(entries.filter_map { |_, _, options| options[:in] }).to all(all(be_a(String)))
    end

    it "leaves GOOGLE_CLIENT_ID unconditional and advisory" do
      expect(entry(:GOOGLE_CLIENT_ID)[2].keys).to eq([:description])
    end

    describe "GOOGLE_CLIENT_SECRET" do
      it "does not apply while the provider is off" do
        expect(StandardId::Providers::Google).not_to be_enabled
        expect(applies?(:GOOGLE_CLIENT_SECRET)).to be(false)
      end

      it "applies once the provider is on and the secret is left to ENV" do
        social.google_client_id = "client-id"

        expect(applies?(:GOOGLE_CLIENT_SECRET)).to be(true)
      end

      it "does not apply when the app assigns the secret itself" do
        social.google_client_id = "client-id"
        social.google_client_secret = "from-credentials"

        expect(applies?(:GOOGLE_CLIENT_SECRET)).to be(false)
      end

      it "does not apply while the deprecated GOOGLE_OAUTH_CLIENT_SECRET supplies it" do
        social.google_client_id = "client-id"
        saved = ENV.fetch("GOOGLE_OAUTH_CLIENT_SECRET", nil)
        ENV["GOOGLE_OAUTH_CLIENT_SECRET"] = "legacy-secret"

        expect(applies?(:GOOGLE_CLIENT_SECRET)).to be(false)
      ensure
        ENV["GOOGLE_OAUTH_CLIENT_SECRET"] = saved
      end
    end

    describe "GOOGLE_REQUIRE_FOR_STAFF" do
      it "is forbidden on production only" do
        expect(entry(:GOOGLE_REQUIRE_FOR_STAFF)[2][:in]).to eq(%w[production])
      end

      it "does not apply while staff enforcement is on (the default)" do
        expect(applies?(:GOOGLE_REQUIRE_FOR_STAFF)).to be(false)
      end

      it "applies when it switches staff enforcement off" do
        social.google_require_for_staff = false

        expect(applies?(:GOOGLE_REQUIRE_FOR_STAFF)).to be(true)
      end
    end
  end
end
