#!/bin/bash

############
# API MAIN #
############

function cdx_ceph_api {
  case $1 in
    start_all_osds|stop_all_osds|restart_all_osds|get_active_osd_nums|run_osds)
      # Commands need docker
      source cdx/osd.sh
      check_osd_env
      $@
      ;;
    set_max_mon|get_max_mon|set_max_osd|get_max_osd|fix_monitor|ceph_verify)
      # Commands in this script
      $@
      ;;
    *)
      log "WARN- Wrong options. See function cdx_ceph_api."
      ;;
  esac
}

function remove_monitor {
  if [ -z "$1" ]; then
    log "ERROR- Usage: remove_monitor MON_name"
    exit 1
  else
    local MON_2_REMOVE=$1
  fi

  get_ceph_admin force &>/dev/null

  if ceph "${CLI_OPTS[@]}" mon remove "${MON_2_REMOVE}" 2>>/tmp/ceph_mon_remove_err; then
    log "${MON_2_REMOVE} has been removed."
    get_ceph_admin force &>/dev/null
  else
    log "ERROR- Failes to remove ${MON_2_REMOVE}"
    cat /tmp/ceph_mon_remove_err
    exit 1
  fi

  if [ "${KV_TYPE}" == "etcd" ]; then
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/mon_host/"${MON_2_REMOVE}" &>/dev/null || true
    source cdx/mon.sh
    update_etcd_monmap &>/dev/null &
  fi
}

function fix_monitor {
  get_ceph_admin force &>/dev/null

  if ! HEALTH_LOG=$(ceph "${CLI_OPTS[@]}" status -f json 2>/dev/null); then
    log "ERROR- Failed to get Ceph status."
    exit 1
  fi

  local MON_DOWN_STATUS=$(echo "${HEALTH_LOG}" | jq -r .health.checks.MON_DOWN.severity)

  if [ "${MON_DOWN_STATUS}" == "null" ]; then
    log "No monitor is down."
    return 0
  fi

  local MON_LIST=$(echo "${HEALTH_LOG}" | jq -r .monmap.mons[].name)
  local MON_DOWN_MSG=$(echo "${HEALTH_LOG}" | jq -r .health.checks.MON_DOWN.summary.messag)
  local MON_UP_LIST=$(echo "${HEALTH_LOG}"  | jq -r .quorum_names[])
  local MON_DOWN_LIST=""

  for mon in ${MON_LIST}; do
    grep -q -w "${mon}" <<< "${MON_UP_LIST}" || MON_DOWN_LIST="${MON_DOWN_LIST} ${mon}"
  done

  for mon in ${MON_DOWN_LIST}; do
    remove_monitor "${mon}"
  done
}

function set_max_mon {
  if ! natural_num $1; then
    log "ERROR- Usage: set_max_mon 1~5"
  else
    local max_mon_num="$1"
  fi

  if etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/max_mon "${max_mon_num}"; then
    log "Expect MON number is $1."
  else
    log "ERROR- Fail to set MAX_MON."
    return 1
  fi
}

function get_max_mon {
  local MAX_MON=""
  if MAX_MON=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/max_mon); then
    echo "${MAX_MON}"
  else
    log "ERROR- Fail to get MAX_MON."
    return 1
  fi
}

function set_max_osd {
  if ! natural_num $1; then
    log "ERROR- Usage: set_max_mon natural_number."
  else
    local max_osd_num="$1"
  fi

  if etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/max_osd "${max_osd_num}"; then
    log "Set MAX_OSD to ${max_osd_num}."
  else
    log "ERROR- Fail to set MAX_OSD."
    return 1
  fi
}

function get_max_osd {
  local MAX_OSD=""
  if MAX_OSD=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/max_osd); then
    echo "${MAX_OSD}"
  else
    log "ERROR- Fail to get max_osd"
    return 1
  fi
}

function ceph_verify {
  local C_POD=$(kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get pod \
    2>/dev/null | awk '/controller-/ {print $1}' | head -1)
  # If conteoller POD is running, then use it to verify.
  local OPTS=$@
  if [ -n "${C_POD}" ]; then
    kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" exec "${C_POD}"  -- bash -c "${OPTS} /entrypoint.sh cdx_verify"
  else
    log "ERROR- Kubenetes controller not exists."
  fi
}
