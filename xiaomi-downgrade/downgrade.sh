#!/bin/sh

# xiaomi be6500pro downgrade script

mkdir -p /tmp/ftp/
mv miwifi.bin /tmp/ftp/

sudo dnsmasql -d -C dnsmasq.conf
# press reset on the device and connect power cord. wait 10 seconds, release reset
