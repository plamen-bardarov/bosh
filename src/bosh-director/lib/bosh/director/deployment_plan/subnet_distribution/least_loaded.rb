module Bosh
  module Director
    module DeploymentPlan
      module SubnetDistribution
        # Least-loaded strategy: order candidate subnets so new VMs spread evenly
        # across the subnets of an AZ.
        #
        # Subnets are tried least-loaded first (by count of dynamic IPs already
        # allocated in that subnet), with manifest order as a stable tiebreak.
        # Existing instances reuse their DB-backed reservation and never reach this
        # path, so their IPs count as load and scale-up naturally fills the emptier
        # subnet.
        #
        # nic_group co-location: networks that share a nic_group land on one NIC/ENI,
        # and IaaS (e.g. AWS) requires every address on one ENI to come from the same
        # subnet. So when a same-nic_group sibling has already been assigned an IP for
        # this instance, this reservation is pinned to that sibling's subnet (matched
        # by cloud_properties) instead of being balanced independently — otherwise the
        # per-network least-loaded sort could scatter the siblings across different
        # subnets. Whichever sibling reserves first is the "leader" and balances freely;
        # the rest follow it. Order-independent.
        class LeastLoaded
          # @networks is the name-keyed Hash built in CloudPlanner; used to resolve a
          # sibling row's network back to its ManualNetwork for co-location.
          def initialize(networks)
            @networks = networks
          end

          def order(candidates, reservation)
            leader_props = nic_group_leader_cloud_properties(reservation)
            if leader_props
              pinned = candidates.select { |subnet| subnet.cloud_properties == leader_props }
              # Empty => the leader's subnet is not among this network's candidates;
              # fall through to least-loaded rather than failing to reserve at all.
              return pinned unless pinned.empty?
            end

            counts = dynamic_ip_counts_by_subnet(reservation.network, candidates)
            candidates.each_with_index
                      .sort_by { |subnet, idx| [counts[subnet], idx] }
                      .map(&:first)
          end

          private

          # cloud_properties of the subnet a same-nic_group sibling was already assigned
          # to for this instance, or nil if there is no sibling yet (this reservation is
          # the leader), the reservation has no nic_group, or the sibling network cannot
          # be resolved. @networks is the name-keyed Hash built in CloudPlanner; some
          # specs pass a non-Hash collection, in which case co-location is simply skipped.
          def nic_group_leader_cloud_properties(reservation)
            return nil unless reservation.nic_group
            return nil unless reservation.instance_model
            return nil unless @networks.is_a?(Hash)

            sibling = Models::IpAddress
                      .where(instance_id: reservation.instance_model.id,
                             nic_group: reservation.nic_group,
                             static: false)
                      .exclude(network_name: reservation.network.name)
                      .first
            return nil unless sibling

            sibling_network = @networks[sibling.network_name]
            return nil unless sibling_network

            subnet = sibling_network.find_subnet_containing(sibling.address)
            subnet&.cloud_properties
          end

          def dynamic_ip_counts_by_subnet(network, candidates)
            counts = candidates.to_h { |subnet| [subnet, 0] }
            Models::IpAddress.where(network_name: network.name, static: false).each do |addr|
              subnet = network.find_subnet_containing(addr.address)
              counts[subnet] += 1 if counts.key?(subnet)
            end
            counts
          end
        end
      end
    end
  end
end
