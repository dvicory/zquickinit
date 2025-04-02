#!/bin/bash

source /zquick/libexec/utils.sh

if ! grep -q "^127.0.0.1[[:space:]]\+localhost" /etc/hosts; then
	touch /etc/hosts
	echo "127.0.0.1 localhost" >> /etc/hosts
fi

# this is a one time task
[[ -f /zquick/run/ifup ]] && exit 0
qinitlog "Starting network interfaces"

qinitlog "Starting background task to monitor connection"
/zquick/libexec/net/check-connection.sh &

mkdir -p /zquick/run
touch /zquick/run/ifup

mkdir -p /var/lib/dhcp
mkdir -p /etc/dhcp
[[ ! -e /etc/fstab ]] && rm -f /etc/fstab
touch /etc/fstab
[[ ! -e /etc/resolv.conf ]] && rm -f /etc/resolv.conf
touch /etc/resolv.conf

cat >/etc/dhcp/dhclient.conf <<-EOF
	timeout 30;
	option classless-static-routes code 121 = array of unsigned integer 8;
	send dhcp-client-identifier = hardware;
	request subnet-mask, broadcast-address, time-offset, routers,
		domain-name, domain-name-servers, domain-search, host-name,
		root-path, interface-mtu, classless-static-routes,
		netbios-name-servers, netbios-scope, ntp-servers,
		dhcp6.domain-search, dhcp6.fqdn,
		dhcp6.name-servers, dhcp6.sntp-servers;
EOF

# Get a list of all network interfaces
interfaces=$(ip link show | awk -F': ' '/^[0-9]+:/ && !/^[0-9]+: lo/{print $2}')

# Execute /etc/network/configure if it exists
if [[ -f /etc/network/configure ]]; then
	qinitlog "Executing /etc/network/configure"
	if ! bash /etc/network/configure; then
		qinitlog "Failed to execute /etc/network/configure"
	else
		qinitlog "Finished executing /etc/network/configure"
	fi
else
	qinitlog "No network configuration found. Enabling DHCP on all interfaces."
fi

# Get a list of interfaces with static IP addresses (both IPv4 and IPv6)
static_interfaces=$(ip -o addr show | awk '/inet/ && !/dynamic/ && !/temporary/{print $2}' | sort -u)

# Filter out interfaces with static IP addresses
for interface in $static_interfaces; do
	interfaces=$(echo "$interfaces" | grep -v "^$interface$")
done

# Bring up each interface
for interface in $interfaces; do
	qinitlog_start "Set link up: $interface"
	if status=$(ip link set "$interface" up); then
		qinitlog_end " [ OK ]"
	else
		qinitlog_end " [ FAILED ] ${status}"
	fi
	# [[ $interface == 'lo' ]] && continue
	# qinitlog "DHCP client (dhclient): [$interface]"
	# dhclient "$interface" -lf /var/lib/dhcp/dhclient.leases -nw || :
done

# Run dhclient once for remaining interfaces
if [ -n "$interfaces" ]; then
	qinitlog "Starting DHCP client for interfaces: [$interfaces]"
	dhclient $interfaces -lf /var/lib/dhcp/dhclient.leases -nw || :
fi

qinitlog "Starting network services"
/zquick/libexec/run_hooks.sh ifup.d
