module Travis
  module Addons
    module GithubStatus

      # Adds a comment with a build notification to the pull-request the request
      # belongs to.
      class Task < Travis::Task
        STATES = {
          'created'  => 'pending',
          'queued'   => 'pending',
          'started'  => 'pending',
          'passed'   => 'success',
          'failed'   => 'failure',
          'errored'  => 'error',
          'canceled' => 'error',
        }

        DESCRIPTIONS = {
          'pending' => 'The Travis build is in progress',
          'success' => 'The Travis build passed',
          'failure' => 'The Travis build failed',
          'error'   => 'The Travis build could not complete due to an error',
        }

        def url
          "/repos/#{repository[:slug]}/statuses/#{sha}"
        end

        private

          def process
            info("Update commit status on #{url} to #{state}")
            authenticated do
              GH.post(url, :state => state, :description => description, :target_url => target_url)
            end
          rescue GH::Error => e
            error "Could not update the PR status on #{GH.api_host + url} (#{e.message})."
          end

          def target_url
            "#{Travis.config.http_host}/#{repository[:slug]}/builds/#{build[:id]}"
          end

          def sha
            pull_request? ? request[:head_commit] : commit[:sha]
          end

          def state
            STATES[build[:state]]
          end

          def description
            DESCRIPTIONS[state]
          end

          def authenticated(&block)
            GH.with(http_options, &block)
          end

          def http_options
            super.merge(token: params[:token])
          end

          Instruments::Task.attach_to(self)
      end
    end
  end
end

