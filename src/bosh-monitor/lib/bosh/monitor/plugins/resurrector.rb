# This health monitor plugin should be used in conjunction with another plugin that
# alerts when a VM is unresponsive, as this plugin will try to automatically fix the
# problem by recreating the VM
module Bosh::Monitor
  module Plugins
    class Resurrector < Base
      include Bosh::Monitor::Plugins::HttpRequestHelper

      def initialize(options={})
        super(options)
        director = @options['director']
        raise ArgumentError 'director options not set' unless director

        @uri                  = URI(director['endpoint'])
        @director_options     = director
        @processor            = Bhm.event_processor
        @resurrection_manager = Bhm.resurrection_manager
        @alert_tracker        = ResurrectorHelper::AlertTracker.new(@options)
      end

      def run
        unless EM.reactor_running?
          logger.error("Resurrector plugin can only be started when event loop is running")
          return false
        end

        logger.info("Resurrector is running...")
      end

      def process(alert)
        deployment = alert.attributes['deployment']
        jobs_to_instance_ids = alert.attributes['jobs_to_instance_ids']
        category = alert.attributes['category']

        # deployment, job, and id are only present for 'agent timed out' and 'vm missing for instance'
        # on the alert so this won't trigger a recreate for other types of alerts
        if category == Bosh::Monitor::Events::Alert::CATEGORY_DEPLOYMENT_HEALTH && deployment && !jobs_to_instance_ids.empty?
          agent_key = ResurrectorHelper::JobInstanceKey.new(deployment, job, id)
          @alert_tracker.record(agent_key, alert)

          unless director_info
            logger.error("(Resurrector) director is not responding with the status")
            return
          end

          request = {
              head: {
                  'Content-Type' => 'application/json',
                  'authorization' => auth_provider(director_info).auth_header
              },
              body: JSON.dump({'jobs' => jobs_to_instance_ids})
          }

          state = @alert_tracker.state_for(deployment)

          if state.meltdown?
            summary = "Skipping resurrection for deployment: '#{deployment}'; #{state.summary}"
            @processor.process(
              :alert,
              severity: 1,
              title: 'We are in meltdown',
              summary: summary,
              source: 'HM plugin resurrector',
              deployment: deployment,
              created_at: Time.now.to_i,
            )
          elsif state.managed?
            if @resurrection_manager.resurrection_enabled?(deployment, job)
              url = @uri.dup
              url.path = "/deployments/#{deployment}/scan_and_fix"
              summary = "Notifying Director to resurrect deployment: '#{deployment}'; #{state.summary}"
              @processor.process(
                :alert,
                severity: 4,
                title: 'Recreating unresponsive VM',
                summary: summary,
                source: 'HM plugin resurrector',
                deployment: deployment,
                created_at: Time.now.to_i,
              )
              send_http_put_request(url.to_s, request)
            else
              summary = "Skipping resurrection for deployment: '#{deployment}'; #{state.summary} because of resurrection config"
              @processor.process(
                :alert,
                severity: 1,
                title: 'Resurrection is disabled by resurrection config',
                summary: summary,
                source: 'HM plugin resurrector',
                deployment: deployment,
                created_at: Time.now.to_i,
              )
            end
          else
            logger.info('(Resurrector) state is normal')
          end
        else
          logger.warn("(Resurrector) event did not have deployment, job and id: #{alert}")
        end
      end

      private

      def auth_provider(director_info)
        @auth_provider ||= AuthProvider.new(director_info, @director_options, logger)
      end

      def director_info
        return @director_info if @director_info

        url = @uri.dup
        url.path = '/info'
        response = send_http_get_request(url.to_s)
        return nil if response.status_code != 200

        @director_info = JSON.parse(response.body)
      end
    end
  end
end
