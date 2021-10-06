require 'simplecov'

SimpleCov.command_name 'Cucumber'

require 'aruba/cucumber'

require_relative '../../spec/helpers/faker'

ModuleSync::Faker.working_directory = File.expand_path('faker', Aruba.config.working_directory)

Before do
  @aruba_timeout_seconds = 5
end
