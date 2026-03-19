#!/bin/bash
set -e

if ! grep "ogstun" /proc/net/dev > /dev/null; then
    ip tuntap add name ogstun mode tun
fi

if test "x$(sysctl -n net.ipv6.conf.ogstun.disable_ipv6)" = x1; then
    echo "net.ipv6.conf.ogstun.disable_ipv6=0" > /etc/sysctl.d/30-open5gs.conf
    sysctl -p /etc/sysctl.d/30-open5gs.conf
fi

ip addr del 10.45.0.1/16 dev ogstun 2> /dev/null
ip addr add 10.45.0.1/16 dev ogstun
ip addr del 2001:db8:cafe::1/48 dev ogstun 2> /dev/null
ip addr add 2001:db8:cafe::1/48 dev ogstun

ip addr del 10.46.0.1/16 dev ogstun2 2> /dev/null
ip addr add 10.46.0.1/16 dev ogstun2
ip addr del 2001:db8:babe::1/48 dev ogstun2 2> /dev/null
ip addr add 2001:db8:babe::1/48 dev ogstun2

ip addr del 10.47.0.1/16 dev ogstun3 2> /dev/null
ip addr add 10.47.0.1/16 dev ogstun3
ip addr del 2001:db8:face::1/48 dev ogstun3 2> /dev/null
ip addr add 2001:db8:face::1/48 dev ogstun3

ip link set ogstun up

mkdir -p /var/log /var/lib/mongodb
mongod --fork --logpath /var/log/mongodb.log --dbpath /var/lib/mongodb

exec /bin/bash
