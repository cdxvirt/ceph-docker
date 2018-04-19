#!/bin/bash

function get_mon_ip_from_public {
  if [ -n "${CEPH_PUBLIC_NETWORK}" ]; then
    MON_IP=$(ip -4 -o a | awk '{ sub ("/..", "", $4); print $4 }' | grepcidr "${CEPH_PUBLIC_NETWORK}" \
      2>/dev/null) || log "ERROR- No IP match CEPH_PUBLIC_NETWORK."
  fi
}

function populate_etcd {
  if [ "${KV_TYPE}" != "etcd" ]; then
    return 0
  elif etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/monSetupComplete &> /dev/null; then
    return 0
  else
    source populate_kv.sh
    populate_kv
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/osd/cluster_network "${CEPH_CLUSTER_NETWORK}"
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/osd/public_network "${CEPH_PUBLIC_NETWORK}"
  fi
}

function remove_mon_lock {
  if local LOCKER_NAME=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/lock 2>/dev/null) && \
    [[ "${LOCKER_NAME}" == "${MON_NAME}" ]]; then
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/lock &>/dev/null
    log "WARN- Removed the previous mon lock key by ${MON_NAME}"
  fi
}

function verify_mon_folder {
  # Found monitor folder or leave.
  local MON_FOLDER_NUM=$(ls -d "${MON_ROOT_DIR}"*/ 2>/dev/null | grep "${CLUSTER}" | wc -w)
  if [ "${MON_FOLDER_NUM}" -eq 0 ]; then
    return 0
  elif [ -d "${MON_ROOT_DIR}""${CLUSTER}"-"${MON_NAME}" ]; then
    return 0
  fi

  if [ "${MON_FOLDER_NUM}" -gt 1 ]; then
    log "ERROR- More than one ceph monitor folders in ${MON_ROOT_DIR}"
    exit 1
  else
    mv $(ls -d "${MON_ROOT_DIR}"*/) "${MON_ROOT_DIR}""${CLUSTER}"-"${MON_NAME}"
    log "Renamed the folder of monitor data to ${CLUSTER}-${MON_NAME}"
  fi
}

function update_monmap {
  if [ ! -d "${MON_ROOT_DIR}""${CLUSTER}"-"${MON_NAME}" ]; then
    return 0
  fi

  if etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/monmap | uudecode -o /tmp/monmap; then
    log "Got the monmap from ETCD."
  else
    log "ERROR- Failed to get latest monmap from ETCD."
    return 0
  fi

  if ceph-mon "${CLI_OPTS[@]}" -i "${MON_NAME}" --inject-monmap /tmp/monmap &>/dev/null; then
    log "Updated monmap in monitor folder."
  else
    log "ERROR- Failed to inject monmap in monitor folder."
  fi
}

function update_etcd_monmap {
  if [ "$1" == "boot" ]; then
    until ps 1 | grep -q ceph-mon; do
      sleep 5
    done
  fi
  sleep 30
  if timeout 10 ceph "${CLI_OPTS[@]}" mon getmap -o /tmp/monmap; then
    log "Got the latest monmap."
  else
    log "ERROR- Failed to get latest monmap. Please check Ceph status."
    return 0
  fi
  if uuencode /tmp/monmap - | etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/monmap &>/dev/null; then
    log "Updated monmap on ETCD."
  else
    log "ERROR- Failed to update monmap on ETCD."
  fi
}

function recovery_mon {
  verify_mon_folder

  # remove all monmap list then add itself
  log "Remove old monitor info on the monmap"
  ceph-mon -i ${MON_NAME} --extract-monmap /tmp/monmap &>/dev/null
  local MONMAP_LIST=$(monmaptool -p /tmp/monmap | awk '/mon\./ { sub ("mon.", "", $3); print $3}')
  for del_mon in ${MONMAP_LIST}; do
    monmaptool --rm $del_mon /tmp/monmap &>/dev/null
  done

  # add itself into monmap
  log "Update monitor info in the monmap"
  monmaptool --add ${MON_NAME} ${MON_IP}:6789 /tmp/monmap &>/dev/null
  ceph-mon -i ${MON_NAME} --inject-monmap /tmp/monmap &>/dev/null
  echo ""
  monmaptool -p /tmp/monmap

  # update ETCD (include monmap & mon_host)
  if uuencode /tmp/monmap - | etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/monmap &>/dev/null; then
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/mon_host --recursive &>/dev/null || true
    echo ""
    log "Success & Exit"
  else
    log "ERROR- Fail to upload monmap to ETCD"
    exit 1
  fi
}


## MAIN
function cdx_mon {
  get_mon_ip_from_public

  if [ "${MON_RCY}" == "true" ]; then
    recovery_mon
    exit 0
  fi

  if [ "${KV_TYPE}" == "etcd" ]; then
    populate_etcd
    remove_mon_lock
    verify_mon_folder
    update_monmap
    update_etcd_monmap boot&
  fi

  if [ -e "$MON_DATA_DIR/keyring" ]; then
    get_mon_config
  fi
}
