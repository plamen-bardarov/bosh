require 'spec_helper'

module Bosh::Director::DeploymentPlan
  module SubnetDistribution
    describe LeastLoaded do
      include Bosh::Director::IpUtil

      subject(:strategy) { described_class.new(networks) }

      let(:instance_model) { FactoryBot.create(:models_instance, availability_zone: 'az-2') }
      let(:nic_group) { 7 }

      # Primary IPv4 network. az-2 has two candidate subnets on distinct IaaS
      # subnets ('aws-2', 'aws-3'); with no load, manifest order picks aws-2 first.
      let(:ipv4_network) do
        ManualNetwork.parse(
          {
            'name' => 'ipv4',
            'subnets' => [
              { 'range' => '192.168.1.0/30', 'gateway' => '192.168.1.1',
                'cloud_properties' => { 'subnet' => 'aws-1' }, 'az' => 'az-1' },
              { 'range' => '192.168.2.0/30', 'gateway' => '192.168.2.1',
                'cloud_properties' => { 'subnet' => 'aws-2' }, 'az' => 'az-2' },
              { 'range' => '192.168.3.0/30', 'gateway' => '192.168.3.1',
                'cloud_properties' => { 'subnet' => 'aws-3' }, 'azs' => ['az-2'] },
            ],
          },
          [AvailabilityZone.new('az-1', {}), AvailabilityZone.new('az-2', {})],
          per_spec_logger,
        )
      end

      # IPv6 sibling networks sharing the same ENI as the IPv4 network (nic_group).
      # They mirror the same IaaS subnets by cloud_properties, on their own IPv6
      # ranges — the diego-cells IPv6-single / IPv6-prefix topology.
      let(:ipv6_single_network) do
        ManualNetwork.parse(
          {
            'name' => 'ipv6-single',
            'subnets' => [
              { 'range' => 'fd00:2::/120', 'gateway' => 'fd00:2::1', 'cloud_properties' => { 'subnet' => 'aws-2' } },
              { 'range' => 'fd00:3::/120', 'gateway' => 'fd00:3::1', 'cloud_properties' => { 'subnet' => 'aws-3' } },
            ],
          },
          [],
          per_spec_logger,
        )
      end
      let(:ipv6_prefix_network) do
        ManualNetwork.parse(
          {
            'name' => 'ipv6-prefix',
            'subnets' => [
              { 'range' => 'fd00:12::/120', 'gateway' => 'fd00:12::1', 'cloud_properties' => { 'subnet' => 'aws-2' } },
              { 'range' => 'fd00:13::/120', 'gateway' => 'fd00:13::1', 'cloud_properties' => { 'subnet' => 'aws-3' } },
            ],
          },
          [],
          per_spec_logger,
        )
      end

      let(:networks) do
        {
          'ipv4' => ipv4_network,
          'ipv6-single' => ipv6_single_network,
          'ipv6-prefix' => ipv6_prefix_network,
        }
      end

      # A subnet by its IaaS subnet id, on whichever network.
      def subnet_on(network, aws)
        network.subnets.find { |s| s.cloud_properties == { 'subnet' => aws } }
      end

      # Seed a dynamic IP as load on a network (no instance/nic_group relevance).
      def seed_load(network_name, address_str)
        FactoryBot.create(:models_ip_address, network_name: network_name, address_str: address_str, static: false)
      end

      # Seed a same-instance sibling reservation carrying a nic_group.
      def seed_sibling(network_name, address_str, group: nic_group)
        FactoryBot.create(
          :models_ip_address,
          instance: instance_model,
          network_name: network_name,
          address_str: address_str,
          static: false,
          nic_group: group,
        )
      end

      describe '#order (least-loaded balancing, no nic_group)' do
        let(:reservation) { Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv4_network) }
        let(:candidates) { [subnet_on(ipv4_network, 'aws-2'), subnet_on(ipv4_network, 'aws-3')] }

        it 'orders least-loaded subnet first' do
          seed_load('ipv4', '192.168.2.1/32')
          seed_load('ipv4', '192.168.2.2/32')

          expect(strategy.order(candidates, reservation))
            .to eq([subnet_on(ipv4_network, 'aws-3'), subnet_on(ipv4_network, 'aws-2')])
        end

        it 'keeps manifest order as a stable tiebreak when load is equal' do
          expect(strategy.order(candidates, reservation)).to eq(candidates)
        end
      end

      describe '#order (nic_group co-location — matching ENIs)' do
        it 'pins an IPv4 follower to the subnet an IPv4 sibling already uses' do
          # Sibling (ipv6-single, but any same-nic_group network) landed on aws-3.
          seed_sibling('ipv6-single', 'fd00:3::5/128')
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv4_network, nic_group)
          candidates = [subnet_on(ipv4_network, 'aws-2'), subnet_on(ipv4_network, 'aws-3')]

          # Empty pools would pick aws-2 (manifest order); co-location forces aws-3.
          expect(strategy.order(candidates, reservation)).to eq([subnet_on(ipv4_network, 'aws-3')])
        end

        it 'pins an IPv6 follower to the subnet its IPv4 leader already uses' do
          # IPv4 leader landed on aws-3; the IPv6 network must collapse onto the same ENI subnet.
          seed_sibling('ipv4', '192.168.3.1/32')
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv6_prefix_network, nic_group)
          candidates = [subnet_on(ipv6_prefix_network, 'aws-2'), subnet_on(ipv6_prefix_network, 'aws-3')]

          expect(strategy.order(candidates, reservation)).to eq([subnet_on(ipv6_prefix_network, 'aws-3')])
        end

        it 'collapses a three-network ENI (IPv4 + IPv6-single + IPv6-prefix) onto one subnet' do
          # First two siblings of the ENI already landed on aws-3; the third must follow.
          seed_sibling('ipv4', '192.168.3.1/32')
          seed_sibling('ipv6-single', 'fd00:3::5/128')
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv6_prefix_network, nic_group)
          candidates = [subnet_on(ipv6_prefix_network, 'aws-2'), subnet_on(ipv6_prefix_network, 'aws-3')]

          expect(strategy.order(candidates, reservation)).to eq([subnet_on(ipv6_prefix_network, 'aws-3')])
        end

        it 'ignores sibling rows belonging to a different nic_group' do
          seed_sibling('ipv6-single', 'fd00:3::5/128', group: nic_group + 1)
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv4_network, nic_group)
          candidates = [subnet_on(ipv4_network, 'aws-2'), subnet_on(ipv4_network, 'aws-3')]

          expect(strategy.order(candidates, reservation).first).to eq(subnet_on(ipv4_network, 'aws-2'))
        end

        it 'does not co-locate when the reservation has no nic_group' do
          seed_sibling('ipv6-single', 'fd00:3::5/128')
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv4_network)
          candidates = [subnet_on(ipv4_network, 'aws-2'), subnet_on(ipv4_network, 'aws-3')]

          expect(strategy.order(candidates, reservation).first).to eq(subnet_on(ipv4_network, 'aws-2'))
        end

        it 'falls through to least-loaded when the leader subnet is not among the candidates' do
          # Sibling landed on aws-1, which is not one of az-2's candidate subnets.
          seed_sibling('ipv4', '192.168.1.1/32')
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv4_network, nic_group)
          candidates = [subnet_on(ipv4_network, 'aws-2'), subnet_on(ipv4_network, 'aws-3')]

          expect(strategy.order(candidates, reservation)).to eq(candidates)
        end
      end

      describe '#order when networks is not a name-keyed Hash' do
        subject(:strategy) { described_class.new([]) }

        it 'skips co-location and falls back to least-loaded without crashing' do
          seed_sibling('ipv6-single', 'fd00:3::5/128')
          reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance_model, ipv4_network, nic_group)
          candidates = [subnet_on(ipv4_network, 'aws-2'), subnet_on(ipv4_network, 'aws-3')]

          expect { strategy.order(candidates, reservation) }.not_to raise_error
          expect(strategy.order(candidates, reservation).first).to eq(subnet_on(ipv4_network, 'aws-2'))
        end
      end
    end
  end
end
