#!/bin/bash

## original settings
# osd
: "${OSD_JOURNAL_SIZE:=2048}"
: "${OSD_FORCE_ZAP:=1}"

# mds
: "${CEPHFS_CREATE:=1}"
: "${CEPHFS_DATA_POOL_PG:=32}"
: "${CEPHFS_METADATA_POOL_PG:=32}"

# rgw
: "${RGW_CIVETWEB_PORT:=18080}"

# kv settings
: "${KV_TYPE:=etcd}"
: "${KV_IP:=127.0.0.1}"
: "${KV_PORT:=2379}"

## cdxvirt settings
# kubernetes
: "${K8S_NETWORK:=${CEPH_PUBLIC_NETWORK}}"

# osd
: "${CRUSH_TYPE:=space}"
: "${PGs_PER_OSD:=32}"
: "${OSD_INIT_MODE:=minimal}"
: "${MAX_OSD:=99}"
: "${OSD_MEM:=2048M}"
: "${OSD_CPU_CORE:=2}"
: "${RESERVED_SLOT:=20}"

# mon
: "${MON_ROOT_DIR:=/var/lib/ceph/mon/}"

# controller
: "${MAX_MON:=3}"
: "${K8S_NAMESPACE:=ceph}"
: "${POD_LABLE:=ceph-mon}"
: "${MON_POD_SELECTOR:="ceph-mon"}"
: "${K8S_EP_NAME:="ceph-mon"}"
: "${CEPH_DOMAIN_NAME:=${K8S_EP_NAME}.${K8S_NAMESPACE}}"
: "${MON_LABEL:="cdx/ceph-mon"}"

# verify
: "${RBD_VFY_POOL:=rbd}"
: "${RBD_VFY_IMAGE:=rbd-vfy-image}"
: "${RBD_MNT_PATH:=/tmp/rbd-vfy}"
: "${VFY_TEST_FILE:=vfy-test-file}"
: "${CEPHFS_MNT_PATH:=/tmp/cephfs}"
: "${CEPHFS_VFY_FS:=cephfs}"
: "${RGW_VFY_UID:=vfy-rgw}"
: "${RGW_VFY_KEY:=vfyrgwkey}"
: "${RGW_VFY_BUCKET:=RGWVFY}"
: "${RGW_VFY_PORT:=${RGW_CIVETWEB_PORT}}"

# keep empty for default
# HTTP_VFY_PATH=http://192.168.0.3/iso/file
# RGW_VFY_SITE=http://192.168.0.4

function check_k8s_env {
  if [ -n "${KUBERNETES_SERVICE_HOST}" ]; then
    K8S_CERT=(--server=https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT} \
      --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
  else
    K8S_CERT=()
  fi

  if [ -n "${K8S_NAMESPACE}" ]; then
    K8S_NAMESPACE=(--namespace=${K8S_NAMESPACE})
  else
    K8S_NAMESPACE=()
  fi
}

function check_kv_ip {
  local SCHEMA="http://"
  # 1. Search K8S_NETWORK first
  local K8S_NODE_IP=$(ip -4 -o a | awk '{ sub ("/..", "", $4); print $4 }' | grepcidr "$K8S_NETWORK" 2>/dev/null) || true
  if etcdctl --peers "${SCHEMA}${K8S_NODE_IP}:${KV_PORT}" ls &>/dev/null; then
    KV_IP=${K8S_NODE_IP}
    return 0
  fi
  # 2. If container not deploy by K8S, then search FLANNEL_NETWORK
  local FLANNEL_GW=$(route -n | awk '/UG/ {print $2 }' | head -n 1) || true
  if etcdctl --peers "${SCHEMA}${FLANNEL_GW}:${KV_PORT}" ls &>/dev/null; then
    KV_IP=${FLANNEL_GW}
    return 0
  fi
  # 3. The last method, use KV_IP default value
  if etcdctl --peers "${SCHEMA}${KV_IP}:${KV_PORT}" ls &>/dev/null; then
    return 0
  else
    echo "ERROR- Can't connect to ETCD Server. Please check the following settings: "
    echo "ERROR- \$K8S_NETWORK=${K8S_NETWORK}"
    echo "ERROR- \$KV_IP=${KV_IP}"
    exit 1
  fi
}

## MAIN
check_k8s_env
if [ ${KV_TYPE} == "etcd" ]; then
  check_kv_ip
fi

# XXX: We should keep to observe who mounting something in this moment.
rm -r /var/lib/ceph/tmp/tmp.* 2>/dev/null || true

# FIXME: Read dns ip from env
echo -e "search ceph.svc.cluster.local svc.cluster.local cluster.local\nnameserver 10.0.0.10\noptions ndots:5" > /etc/resolv.conf
