require "csv"
require "chartkick"
require "blazer/version"
require "blazer/data_source"
require "blazer/engine"
require "blazer/tasks"

module Blazer
  class << self
    attr_accessor :audit
    attr_reader :time_zone
    attr_accessor :user_name
    attr_accessor :user_class
    attr_accessor :timeout
    attr_accessor :from_email
  end
  self.audit = true
  self.user_name = :name
  self.timeout = 15

  def self.time_zone=(time_zone)
    @time_zone = time_zone.is_a?(ActiveSupport::TimeZone) ? time_zone : ActiveSupport::TimeZone[time_zone.to_s]
  end

  def self.settings
    @settings ||= YAML.load(ERB.new(File.read(Rails.root.join("config", "blazer.yml"))).result)
  end

  def self.data_sources
    @data_sources ||= begin
      ds = Hash[
        settings["data_sources"].map do |id, s|
          [id, Blazer::DataSource.new(id, s)]
        end
      ]
      ds.default = ds.values.first
      ds
    end
  end

  def self.run_checks
    Blazer::Check.includes(:blazer_query).find_each do |check|
      rows = nil
      error = nil
      tries = 0
      # try 3 times on timeout errors
      begin
        rows, error = data_sources[check.blazer_query.data_source].run_statement(check.blazer_query.statement)
        tries += 1
      end while error && error.include?("canceling statement due to statement timeout") && tries < 3
      check.update_state(rows, error)
    end
  end

  def self.send_failing_checks
    emails = {}
    Blazer::Check.includes(:blazer_query).where(state: %w[failing error]).find_each do |check|
      check.split_emails.each do |email|
        (emails[email] ||= []) << check
      end
    end

    emails.each do |email, checks|
      Blazer::CheckMailer.failing_checks(email, checks).deliver_later
    end
  end
end
