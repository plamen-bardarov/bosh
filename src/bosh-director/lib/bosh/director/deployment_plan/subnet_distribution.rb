require 'bosh/director/deployment_plan/subnet_distribution/first_fit'
require 'bosh/director/deployment_plan/subnet_distribution/least_loaded'

module Bosh
  module Director
    module DeploymentPlan
      # Selects how auto-allocated (dynamic) IPs on a manual network are distributed
      # across the subnets of an AZ. Chosen by the director-wide
      # `dynamic_subnet_strategy` config value.
      module SubnetDistribution
        FIRST_FIT    = 'first_fit'.freeze
        LEAST_LOADED = 'least_loaded'.freeze
        DEFAULT      = FIRST_FIT
        ALLOWED      = [FIRST_FIT, LEAST_LOADED].freeze

        def self.build(name, networks:)
          case name
          when LEAST_LOADED
            LeastLoaded.new(networks)
          else
            FirstFit.new
          end
        end
      end
    end
  end
end
