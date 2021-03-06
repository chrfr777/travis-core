require 'active_record'

# Job models a unit of work that is run on a remote worker.
#
# There currently only one job type:
#
#  * Job::Test belongs to a Build (one or many Job::Test instances make up a
#    build matrix) and executes a test suite with parameters defined in the
#    configuration.
class Job < ActiveRecord::Base
  autoload :Compat,    'travis/model/job/compat'
  autoload :Queue,     'travis/model/job/queue'
  autoload :Sponsors,  'travis/model/job/sponsors'
  autoload :Tagging,   'travis/model/job/tagging'
  autoload :Test,      'travis/model/job/test'

  class << self
    # what we return from the json api
    def queued(queue = nil)
      scope = where(state: [:created, :queued])
      scope = scope.where(queue: queue) if queue
      scope
    end

    # what needs to be queued up
    def queueable(queue = nil)
      scope = where(state: :created).order('jobs.id')
      scope = scope.where(queue: queue) if queue
      scope
    end

    # what already is queued or started
    def running(queue = nil)
      scope = where(state: [:queued, :started]).order('jobs.id')
      scope = scope.where(queue: queue) if queue
      scope
    end

    def unfinished
      # TODO conflate Job and Job::Test and use States::FINISHED_STATES
      where('state NOT IN (?)', [:finished, :passed, :failed, :errored, :canceled])
    end

    def owned_by(owner)
      where(owner_id: owner.id, owner_type: owner.class.to_s)
    end
  end

  include Compat
  include Travis::Model::EnvHelpers

  has_one    :log, dependent: :destroy
  has_many   :events, as: :source

  belongs_to :repository
  belongs_to :commit
  belongs_to :source, polymorphic: true, autosave: true
  belongs_to :owner, polymorphic: true

  validates :repository_id, :commit_id, :source_id, :source_type, :owner_id, :owner_type, presence: true

  serialize :config

  delegate :request_id, to: :source # TODO denormalize
  delegate :pull_request?, to: :commit

  after_initialize do
    self.config = {} if config.nil? rescue nil
  end

  before_create do
    build_log
    self.state = :created if self.state.nil?
    self.queue = Queue.for(self).name
  end

  after_commit on: :create do
    notify(:create)
  end

  def propagate(*args)
    source.send(*args)
    true
  end

  def duration
    started_at && finished_at ? finished_at - started_at : nil
  end

  def config=(config)
    super(config ? config.deep_symbolize_keys : {})
  end

  def obfuscated_config
    config.dup.tap do |config|
      next unless config[:env]
      obfuscated_env = process_env(config[:env]) { |env| obfuscate_env(env) }
      config[:env] = obfuscated_env ? obfuscated_env.join(' ') : nil
    end
  end

  def decrypted_config
    self.config.dup.tap do |config|
      config[:env] = process_env(config[:env]) { |env| decrypt_env(env) } if config[:env]
    end
  end

  def matrix_config?(config)
    return false unless config.respond_to?(:to_hash)
    config = config.to_hash.symbolize_keys
    Build.matrix_keys_for(config).map do |key|

      # TODO: this is soooo wrong an hacky :)
      #       The awful piece of code below is here to fix allow_failures
      #       with global env config. Proper solution will be to send
      #       matrix env config and global env config separately, but in order
      #       to do this, we will need to change a way workers fetch config.
      #       It will take a while to roll out those changes to workers and other
      #       parts of architecture, so I will leave this nasty thing here and
      #       clean up as soon as everything is ready.
      if key.to_sym == :env && self.config[:global_env]
        job_env    = Array(self.config[key.to_sym])
        config_env = Array(config[key])
        (job_env - self.config[:global_env]) == config_env
      else
        self.config[key.to_sym] == config[key] || commit.branch == config[key]
      end
    end.inject(:&)
  end

  private

    def process_env(env)
      env = [env] unless env.is_a?(Array)
      env = normalize_env(env)
      env = if pull_request?
        remove_encrypted_env_vars(env)
      else
        yield(env)
      end
      env.compact.presence
    end

    def remove_encrypted_env_vars(env)
      env.reject do |var|
        var.is_a?(Hash) && var.has_key?(:secure)
      end
    end

    def normalize_env(env)
      env.map do |line|
        if line.is_a?(Hash) && !line.has_key?(:secure)
          line.map { |k, v| "#{k}=#{v}" }.join(' ')
        else
          line
        end
      end
    end

    def decrypt_env(env)
      env.map do |var|
        decrypt(var) do |var|
          var.insert(0, 'SECURE ') unless var.include?('SECURE ')
        end
      end
    rescue
      {}
    end

    def decrypt(v, &block)
      repository.key.secure.decrypt(v, &block)
    end
end
