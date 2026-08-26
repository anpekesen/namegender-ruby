Gem::Specification.new do |spec|
  spec.name = "namegender"
  spec.version = "0.2.0"
  spec.summary = "Official Ruby client for the NameGender API"
  spec.description = "A dependency-free Ruby client for name, email, username and bulk lookups through NameGender."
  spec.homepage = "https://namegender.com"
  spec.authors = ["NameGender"]
  spec.email = ["support@namegender.com"]
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0"
  spec.license = "MIT"
  spec.metadata = {
    "homepage_uri" => "https://namegender.com",
    "source_code_uri" => "https://github.com/anpekesen/namegender-ruby",
    "bug_tracker_uri" => "https://github.com/anpekesen/namegender-ruby/issues",
    "documentation_uri" => "https://namegender.com/docs",
    "rubygems_mfa_required" => "true"
  }
end
