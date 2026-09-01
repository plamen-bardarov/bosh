module Bosh
  module Director
    module DeploymentPlan
      module SubnetDistribution
        # Default strategy: try candidate subnets in manifest order, so the first
        # subnet fills until its dynamic pool is exhausted before the next is used.
        # This is byte-for-byte the director's historical behavior.
        class FirstFit
          def order(candidates, _reservation)
            candidates
          end
        end
      end
    end
  end
end
