require "./spec_helper"

describe Bootstrap::SeedHealthcheck do
  it "registers seed healthcheck commands" do
    Bootstrap::CLI.registry.has_key?("seed-healthcheck").should be_true
    Bootstrap::CLI.registry.has_key?("seed-check").should be_true
  end
end
