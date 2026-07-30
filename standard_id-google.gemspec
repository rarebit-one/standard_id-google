# frozen_string_literal: true

require_relative "lib/standard_id/google/version"

Gem::Specification.new do |spec|
  spec.name = "standard_id-google"
  spec.version = StandardId::Google::VERSION
  spec.authors = ["Jaryl Sim"]
  spec.email   = ["code@jaryl.dev"]

  spec.summary = "Google Sign In provider plugin for the StandardId engine."
  spec.description = "Extracted StandardId::Providers::Google implementation packaged as a standalone gem so StandardId installations can opt into Sign in with Google independently."
  spec.homepage = "https://github.com/rarebit-one/standard_id_google"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  # Allow-list, not a reject-list: only these paths ship. A reject-list fails
  # OPEN — anything new in the repo is published unless someone remembers to
  # exclude it, which is exactly how `.claude/` reached published 0.3.0 (#69).
  # Matches the rest of the standard_* family.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["lib/**/*", "LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 8.0"
  # This plugin reaches into standard_id internals (StandardId::ProviderRegistry,
  # StandardId::Providers::Google), so its compatibility with a given standard_id
  # really does need checking rather than assuming.
  #
  # That check is enforced in CI (the `compat` job resolves and tests against the
  # LATEST PUBLISHED standard_id), not by a narrow runtime constraint. A narrow
  # constraint was tried — `~> 0.29.0` — and it failed badly: standard_id went to
  # 0.30, 0.31 and 0.32 with no compatibility check and no plugin release, while
  # the *published* 0.3.0 kept the older loose `~> 0.1` requirement. So consumers
  # ran the untested combination anyway, and the cap sat unreleased on main as a
  # loaded gun: publishing this gem would have forced luminality-web and
  # sidekick-web back to the 0.29 series or broken resolution outright.
  #
  # Resolution-time caps only work if someone acts on every failure. CI failing
  # the maintainer is strictly better than bundler failing five consumers.
  spec.add_dependency "standard_id", ">= 0.29", "< 1.0"
end
