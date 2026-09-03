#!/bin/sh

#Hardcoded values
PACKET_REPEATS=2

function usage()
{
    echo "Usage: $0 <MAC_ADDRESS> <HOST_ADDRESS>"
    echo "Example:"
    echo "    $0 12:34:56:78:9A:BC 192.168.1.255"
}

# Parse CLI attributes
MAC_REGEX='^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$'
MAC_ADDR="$1"
MAC_ADDR=`echo "$MAC_ADDR" | grep -i "$MAC_REGEX"`
if [ -z "$MAC_ADDR" ]
then
    echo "Error: Bad MAC address!"
    usage
    exit 1
fi

HOST="$2"
if [ -z "$HOST" ]
then
    echo "Error: No host given!"
    usage
    exit 2
fi

# Check required programs (nc) exist
NC_WHEREIS=`whereis nc`
if [ -z "$NC_WHEREIS" ]
then
    echo "Error: Could not find NetCat (nc) on your system Path!"
    exit 3
fi

# Build the magic packet which consists of 0xFF 6 times then the MAC
# Address repeated 16 times
MAGIC_PACKET=':FF:FF:FF:FF:FF:FF'
for i in `seq 1 16`
do
    MAGIC_PACKET="$MAGIC_PACKET:$MAC_ADDR"
done
#Replace colons with escape sequences
MAGIC_PACKET=`echo "$MAGIC_PACKET" | sed 's|:|\\\\x|g'`
echo "Sending magic UDP packet for $MAC_ADDR"
#echo -ne "$MAGIC_PACKET" | hexdump -C -v
for i in `seq 1 "$PACKET_REPEATS"`
do
    echo -ne "$MAGIC_PACKET" | nc -w 1 -v -v -u -b "$HOST" 7 || exit 4
done
