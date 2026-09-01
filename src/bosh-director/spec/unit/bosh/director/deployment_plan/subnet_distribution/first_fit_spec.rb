require 'spec_helper'

module Bosh::Director::DeploymentPlan
  module SubnetDistribution
    describe FirstFit do
      subject(:strategy) { described_class.new }

      it 'returns candidate subnets unchanged (manifest order)' do
        candidates = [double('subnet-a'), double('subnet-b'), double('subnet-c')]

        expect(strategy.order(candidates, double('reservation'))).to eq(candidates)
      end
    end
  end
end
