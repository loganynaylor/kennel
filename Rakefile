# frozen_string_literal: true
require "bundler/setup"

require "rubocop/rake_task"
RuboCop::RakeTask.new

desc "Run tests"
task :test do
  sh "forking-test-runner test --merge-coverage --quiet"
end

desc "Ensure there are no uncommited changes that would be hidden from PR reviewers"
task no_diff: :generate do
  sh "git diff HEAD --exit-code -- generated"
end

desc "generate local definitions"
task generate: :environment do
  Kennel.generate
end

# also generate parts so users see and commit updated generated automatically
desc "show planned datadog changes"
task plan: :generate do
  Kennel.plan
end

desc "update datadog"
task update_datadog: :environment do
  Kennel.update
end

desc "comment on github commit with planned datadog changes"
task report_plan_to_github: :environment do
  Kennel.report_plan_to_github
end

desc "update if this is a push to the default branch, otherwise report plan"
task :travis do
  on_default_branch = (ENV["TRAVIS_BRANCH"] == (ENV["DEFAULT_BRANCH"] || "master"))
  is_push = (ENV["TRAVIS_PULL_REQUEST"] == "false")
  task_name =
    if on_default_branch && is_push
      :update_datadog
    elsif ENV["GITHUB_TOKEN"]
      :report_plan_to_github
    else
      :plan
    end
  Rake::Task[task_name].invoke
end

task :environment do
  require "dotenv"
  Dotenv.load

  $LOAD_PATH << "lib"
  require "kennel"
end

# make sure we always run what travis runs
require "yaml"
travis = YAML.load_file(".travis.yml").fetch("env").map { |v| v.delete("TASK=") }
raise if travis.empty?
task default: travis
