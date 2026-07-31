# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "rails/generators"
require "generators/standard_id/google/install/install_generator"

RSpec.describe StandardId::Google::Generators::InstallGenerator do
  let(:destination_root) { @destination_root }
  let(:initializer_path) { File.join(destination_root, "config/initializers/standard_id_google.rb") }

  before do
    @destination_root = Dir.mktmpdir("standard_id_google_generator")
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
  end

  after { FileUtils.rm_rf(destination_root) }

  def run_generator(options = {})
    generator = described_class.new([], options)
    generator.destination_root = destination_root
    silence_stream { generator.invoke_all }
  end

  # The generator says_status and prints an env hint; keep spec output readable.
  def silence_stream
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  it "is registered under the standard_id:google:install namespace" do
    expect(described_class.namespace).to eq("standard_id:google:install")
  end

  it "writes the initializer" do
    run_generator

    expect(File.exist?(initializer_path)).to be true
  end

  it "configures every google field in the social scope" do
    run_generator
    content = File.read(initializer_path)

    expect(content).to include("StandardId.configure")
    expect(content).to include("config.social.google_client_id")
    expect(content).to include("config.social.google_client_secret")
  end

  # The flat form works today only because the name happens to be unique across
  # scopes; it breaks silently the day it isn't. The generated file must never
  # teach it.
  it "never emits the unqualified form" do
    run_generator

    expect(File.read(initializer_path)).not_to match(/^\s*config\.google_/)
  end

  describe "idempotence" do
    it "leaves an existing initializer alone" do
      File.write(initializer_path, "# hand-written\n")
      run_generator

      expect(File.read(initializer_path)).to eq("# hand-written\n")
    end

    it "overwrites with --force" do
      File.write(initializer_path, "# hand-written\n")
      run_generator(force: true)

      expect(File.read(initializer_path)).to include("config.social.google_client_id")
    end

    it "writes nothing with --skip-initializer" do
      run_generator(skip_initializer: true)

      expect(File.exist?(initializer_path)).to be false
    end
  end
end
