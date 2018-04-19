#!/bin/bash
set -e

MON_IPS="$(ip -4 -o a | awk '{ sub ("/..", "", $4); print $4 }' | grepcidr "${CEPH_PUBLIC_NETWORK}")"
MON_PORT="6789"

for MON_IP in ${MON_IPS}; do
  if curl -s "${MON_IP}":"${MON_PORT}" > /dev/null; then
    HEALTHY="true"
    break
  else
    echo " dial tcp ${MON_IP}:${MON_PORT}: getsockopt: connection refused" 1>&2
  fi
done

if [[ "${HEALTHY}" == "true" ]]; then
  exit 0
else
  exit 1
fi
