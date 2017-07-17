#!/bin/bash
set -e

function get_mon_ip_from_public {
  if [ -n "${CEPH_PUBLIC_NETWORK}" ]; then
    MON_IP=$(ip -4 -o a | awk '{ sub ("/..", "", $4); print $4 }' | grepcidr "${CEPH_PUBLIC_NETWORK}" \
      2>/dev/null) || echo "get_mon_ip_from_public error"
  fi
}

function populate_etcd {
  if [ ${KV_TYPE} != "etcd" ]; then
    return 0
  elif etcdctl -C ${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/monSetupComplete > /dev/null 2>&1; then
    return 0
  else
    source populate_kv.sh
    populate_kv
    etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/osd/cluster_network ${CEPH_CLUSTER_NETWORK}
    etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/osd/public_network ${CEPH_PUBLIC_NETWORK}
  fi
}

## MAIN
echo "NOW IN CDX/MON"
if is_cdx_env; then
  get_mon_ip_from_public
  echo "MONIP: $MON_IP"
  echo "KV: ${KV_PORT}"
  echo "KV_TYPE: ${KV_TYPE}"
  populate_etcd
  echo "Check ETCD"
else
  echo "NOT CDX-ENV, RUN OFFICIAL"
fi
