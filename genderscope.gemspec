Gem::Specification.new do |spec|
  spec.name = "genderscope"
  spec.version = "0.1.0"
  spec.summary = "Official Ruby client for the GenderScope API"
  spec.description = "A dependency-free Ruby client for name, email, username and bulk lookups through GenderScope."
  spec.homepage = "https://genderscope.io"
  spec.authors = ["GenderScope"]
  spec.email = ["support@genderscope.io"]
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0"
  spec.license = "MIT"
  spec.metadata = {
    "homepage_uri" => "https://genderscope.io",
    "source_code_uri" => "https://github.com/anpekesen/genderscope-ruby",
    "bug_tracker_uri" => "https://github.com/anpekesen/genderscope-ruby/issues",
    "documentation_uri" => "https://genderscope.io/docs",
    "rubygems_mfa_required" => "true"
  }
end
