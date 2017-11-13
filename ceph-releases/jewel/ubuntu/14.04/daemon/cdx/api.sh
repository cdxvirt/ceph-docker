#!/bin/bash

############
# API MAIN #
############

function cdx_ceph_api {
  case $1 in
    start_all_osds|stop_all_osds|restart_all_osds|get_osd_info|start_or_create_a_osd|stop_a_osd)
      # Commands need docker
      source cdx/osd.sh
      check_docker_cmd
      $@
      ;;
    set_max_mon|get_max_mon|set_max_osd|get_max_osd|fix_monitor|ceph_verify)
      # Commands in this script part 1
      $@
      ;;
    osd_overview|check_replica_avail|set_all_replica|start_osd|stop_osd)
      # Commands in this script part 2
      $@
      ;;
    get_crush_leaf|check_leaf_avail|set_crush_leaf)
      # Commands in this script part 3
      $@
      ;;
    *)
      log "WARN- Wrong options. See function cdx_ceph_api."
      return 2
      ;;
  esac
}

function get_ceph_status {
  get_ceph_admin force &>/dev/null
  if ! HEALTH_LOG=$(ceph "${CLI_OPTS[@]}" status -f json 2>/dev/null); then
    log "ERROR- Failed to get Ceph status."
    exit 1
  fi

  MON_LIST=$(echo "${HEALTH_LOG}" | jq -r .monmap.mons[].name)
  OVERALL_STATUS=$(echo "${HEALTH_LOG}" | jq -r .health.overall_status)

  if [ "${OVERALL_STATUS}" != "HEALTH_OK" ]; then
    HEALTH_DETAIL=$(echo "${HEALTH_LOG}"  | jq -r .health.summary[].summary)
  fi

  if grep -q -w "mons down" <<< "${HEALTH_DETAIL}"; then
    MON_UP_LIST=$(echo "${HEALTH_LOG}"  | jq -r .health.timechecks.mons[].name)
    MON_DOWN_LIST=""
    for mon in ${MON_LIST}; do
      grep -q -w "${mon}" <<< "${MON_UP_LIST}" || MON_DOWN_LIST="${MON_DOWN_LIST} ${mon}"
    done
  fi
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
  get_ceph_status
  if [ -z "${MON_DOWN_LIST}" ]; then
    log "No monitor is down."
    return 0
  fi

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
    2>/dev/null | awk '/ceph-controller-/ {print $1}' | head -1)
  # If conteoller POD is running, then use it to verify.
  local OPTS=$@
  if [ -n "${C_POD}" ]; then
    kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" exec "${C_POD}"  -- bash -c "${OPTS} /entrypoint.sh cdx_verify"
  else
    log "ERROR- Kubenetes controller not exists."
  fi
}

function osd_overview {
  if [ ! -e "${ADMIN_KEYRING}" ]; then
    echo "Ceph Cluster isn't ready. Please try again later."
    return 1
  fi
  local OSD_NAME_LIST=$(kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get pod -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName' --no-headers 2>/dev/null | awk '/ceph-osd-/ {print $2}')
  local J_FORM="{\"data\":{\"balanceStatus\":\"\",\"estimateBalanceTime\":\"\",\"nodes\":[]}}"

  # get balance info
  source cdx/balance.sh
  local BAL_INFO=$(cacl_balance)
  local ADD_LIST=$(echo ${BAL_INFO} | jq --raw-output ".addable")
  local MOV_LIST=$(echo ${BAL_INFO} | jq --raw-output ".movable")
  local BAL_STAT=$(echo ${BAL_INFO} | jq --raw-output ".balance")

  # disk info
  local counter=0
  for osd_name in ${OSD_NAME_LIST}; do
    local J_NODE_STAT=""
    J_NODE_NAME="{\"nodeName\":\"${osd_name}\"}"
    if echo "${MOV_LIST}" | grep -q "${osd_name}"; then
      local J_NODE_STAT="{\"moveDisk\":true}"
    elif echo "${ADD_LIST}" | grep -q "${osd_name}"; then
      local J_NODE_STAT="{\"addDisk\":true}"
    else
      local J_NODE_STAT="{}"
    fi
    J_FORM=$(echo ${J_FORM} | jq ".data.nodes[$counter] |= .+ ${J_NODE_NAME} + ${J_NODE_STAT}")
    let counter=counter+1
  done

  # balance info
  if [ "${BAL_STAT}" == "true" ]; then
    J_FORM=$(echo ${J_FORM} | jq ".data.balanceStatus |= .+ \"balance\"")
  else
    J_FORM=$(echo ${J_FORM} | jq ".data.balanceStatus |= .+ \"inbalance\"")
  fi

  # recovery info
  source cdx/recovery-time.sh
  local TIME=$(cacl_recovery_time)
  J_FORM=$(echo ${J_FORM} | jq ".data.estimateBalanceTime |= .+ \"${TIME}\"")

  echo ${J_FORM}
}

function check_replica_avail {
  if [ ! -e "${ADMIN_KEYRING}" ]; then
    >&2 echo "Ceph Cluster isn't ready. Please try again later."
    return 1
  fi
  local EXP_SIZE=${1}
  if [ -z "${EXP_SIZE}" ]; then
    >&2 echo "FALSE"
    return 2
  elif ! positive_num "${EXP_SIZE}"; then
    >&2 echo "FALSE"
    return 3
  fi
  local POOL_JSON=$(ceph "${CLI_OPTS[@]}" osd pool ls detail -f json 2>/dev/null)
  local CUR_SIZE=$(echo "${POOL_JSON}"  | jq --raw-output .[0].size)

 # check nodes
  local NODE_JSON=$(ceph "${CLI_OPTS[@]}" osd tree -f json | jq --raw-output '.nodes | .[] | select(.type=="host")  | {name}+{children}')
  local NODE_LIST=$(echo "${NODE_JSON}" | jq --raw-output .name)
  local NODES=$(echo "${NODE_LIST}" | wc -w)
  if [ "${EXP_SIZE}" -gt "${NODES}" ]; then
    >&2 echo "FALSE"
    return 4
  fi

  # check space
  local SPACE_JSON=$(ceph "${CLI_OPTS[@]}" df -f json 2>/dev/null)
  local USED_SPACE=$(echo "${SPACE_JSON}" | jq .stats.total_used_bytes)
  local AVAL_SPACE=$(echo "${SPACE_JSON}" | jq .stats.total_avail_bytes)
  local EXP_SPACE=$(expr "${USED_SPACE}" "/" "${CUR_SIZE}" "*" "${EXP_SIZE}")
  if [ "${AVAL_SPACE}" -lt "${EXP_SPACE}" ]; then
    >&2 echo "FALSE"
    return 5
  fi

  echo "TRUE"
}

function set_all_replica {
  local EXP_SIZE=${1}
  check_replica_avail "${EXP_SIZE}" >/dev/null
  local POOL_JSON=$(ceph "${CLI_OPTS[@]}" osd pool ls detail -f json 2>/dev/null)
  local ALL_POOLS=$(echo "${POOL_JSON}"  | jq --raw-output .[].pool_name)
  for pool in ${ALL_POOLS}; do
    ceph "${CLI_OPTS[@]}" osd pool set "${pool}" size "${EXP_SIZE}" &>/dev/null
  done
  echo "SUCCESS"
}

function stop_osd {
  local NODE=${1}
  local DISK=${2}
  if [ -z "${NODE}" ]; then
    echo "ERROR"
    return 1
  elif [ -z "${DISK}" ]; then
    echo "ERROR"
    return 2
  fi
  local PODS=$(kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get pod -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName' --no-headers)
  local O_POD=$(printf "${PODS}" | grep "${NODE}" | awk '/ceph-osd-/ {print $1}')
  kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" exec "${O_POD}" ceph-api stop_a_osd "${DISK}"
}

function start_osd {
  local NODE=${1}
  local DISK=${2}
  local ACT=${3}
  if [ -z "${NODE}" ]; then
    echo "ERROR"
    return 1
  elif [ -z "${DISK}" ]; then
    echo "ERROR"
    return 2
  fi
  local PODS=$(kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get pod -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName' --no-headers)
  local O_POD=$(printf "${PODS}" | grep "${NODE}" | awk '/ceph-osd-/ {print $1}')
  kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" exec "${O_POD}" ceph-api start_or_create_a_osd "${DISK}" "${ACT}"
}

function check_leaf_avail {
  local REPLICA=$(ceph "${CLI_OPTS[@]}" osd pool ls detail -f json 2>/dev/null | jq --raw-output .[0].size)
  local NODE_JSON=$(ceph "${CLI_OPTS[@]}" osd tree -f json | jq --raw-output '.nodes[] | select(.type=="host") | {"name": (.name), "number": (.children | length)}')
  local AVAL_NODES=$(echo "${NODE_JSON}" | jq --raw-output ' . | select(.number>0) | .name' | wc -w)

  if [ "${AVAL_NODES}" -ge "${REPLICA}" ]; then
    echo "HOST"
  else
    echo "OSD"
  fi
}

function get_crush_leaf {
  local CRUSH_RULE=$(ceph "${CLI_OPTS[@]}" osd pool ls detail -f json 2>/dev/null | jq --raw-output .[0].crush_ruleset)
  case ${CRUSH_RULE} in
    0)
      echo "HOST"
      ;;
    1)
      echo "OSD"
      ;;
    *)
      >&2 echo "FALSE"
      return 1
      ;;
  esac
}

function set_crush_leaf {
  local EXP_LEAF=${1}
  local AVAIL_LEAF=$(check_leaf_avail)
  local SET_LEAF=""
  if [ "${EXP_LEAF}" != "OSD" ] && [ "${EXP_LEAF}" != "HOST" ]; then
    >&2 echo "FALSE"
    return 1
  elif [ "${EXP_LEAF}" == "HOST" ] && [ "${AVAIL_LEAF}" == "OSD" ]; then
    >&2 echo "FALSE"
    return 2
  fi

  local POOL_JSON=$(ceph "${CLI_OPTS[@]}" osd pool ls detail -f json 2>/dev/null)
  local ALL_POOLS=$(echo "${POOL_JSON}"  | jq --raw-output .[].pool_name)
  case ${EXP_LEAF} in
    OSD)
      local CRUSH_RULE=1
      ;;
    HOST)
      local CRUSH_RULE=0
      ;;
    *)
      >&2 echo "FALSE"
      ;;
    esac

  for pool in ${ALL_POOLS}; do
    ceph "${CLI_OPTS[@]}" osd pool set "${pool}" crush_ruleset "${CRUSH_RULE}" &>/dev/null
  done
  echo "SUCCESS"
}
