#!/bin/bash
set -e

MON_IP=$(ip -4 -o a | awk '{ sub ("/..", "", $4); print $4 }' | grepcidr "${CEPH_PUBLIC_NETWORK}")
MON_PORT=6789

if ! curl -d "null" "$MON_IP":"$MON_PORT"; then
  echo " dial tcp $MON_IP:$MON_PORT: getsockopt: connection refused"
  exit 1
fi
