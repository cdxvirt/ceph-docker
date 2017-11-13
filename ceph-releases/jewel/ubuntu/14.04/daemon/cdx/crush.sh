#!/bin/bash

##############
# CRUSH INIT #
##############

function crush_initialization {
  # check ceph command is usable
  until timeout 10 ceph "${CLI_OPTS[@]}" health &>/dev/null; do
    log "WARN- Waitiing for ceph cluster ready."
  done

  # set lock to avoid multiple node writting together
  until etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "${CLUSTER_PATH}"/osd_init_lock "${HOSTNAME}" &>/dev/null; do
    local LOCKER_NAME=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/osd_init_lock)
    if [[ "${LOCKER_NAME}" == "${HOSTNAME}" ]]; then
      log "WARN- Last time Crush Initialization is locked by ${HOSTNAME} itself."
      break
    else
      log "WARN- Crush Initialization is locked by ${LOCKER_NAME}. Waiting..."
      sleep 3
    fi
  done

  # check complete status
  if etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/initialization_complete &>/dev/null; then
    log "We detected a complete status, no need to initialize."
  else
    log "Initialization of crushmap"
    # create a crush rule, chooseleaf as osd.
    ceph "${CLI_OPTS[@]}" osd crush rule create-simple replicated_type_osd default osd firstn
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/initialization_complete true &>/dev/null
  fi

  log "Removing lock for ${HOSTNAME}"
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/osd_init_lock &>/dev/null || true
}


################
# CRUSH ADJUST #
################

function auto_change_crush {
  # DO NOT EDIT DEFAULT POOL
  RBD_POOL=rbd
  DEFAULT_POOLS="rbd cephfs_data cephfs_metadata .rgw.root default.rgw.control default.rgw.data.root default.rgw.gc default.rgw.log default.rgw.users.uid default.rgw.buckets.data default.rgw.buckets.index default.rgw.users.keys default.rgw.meta default.rgw.buckets.non-ec"
  CURRENT_POOLS=""
  for pool in $(rados "${CLI_OPTS[@]}" lspools 2>/dev/null); do
    if grep -o -q ${pool} <<< "${DEFAULT_POOLS}"; then
      CURRENT_POOLS="${CURRENT_POOLS} ${pool}"
    fi
  done

  # If there are no osds, We don't change crush
  health_log=$(timeout 10 ceph "${CLI_OPTS[@]}" health 2>/dev/null)
  if echo "${health_log}" | grep -q "no osds"; then
    return 0
  fi

  # set lock to avoid multiple node writting together
  until etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "${CLUSTER_PATH}"/osd_crush_lock "${HOSTNAME}" &>/dev/null; do
    local LOCKER_NAME=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/osd_crush_lock)
    if [[ "${LOCKER_NAME}" == "${HOSTNAME}" ]]; then
      log "WARN- Last time auto_change_crush is locked by ${HOSTNAME} itself."
      break
    else
      log "WARN -Auto_change_crush is locked by ${LOCKER_NAME}. Waiting..."
      sleep 10
    fi
  done

  # NODES not include some host weight=0
  NODEs=$(ceph "${CLI_OPTS[@]}" osd tree | awk '/host/ { print $2 }' | grep -v ^0$ -c || true)
  # Only count OSD that status is up
  OSDs=$(ceph "${CLI_OPTS[@]}" osd stat -f json 2>/dev/null | jq --raw-output ".num_up_osds")
  # Put crush type into ETCD
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/crush_type "${CRUSH_TYPE}" &>/dev/null

  case "${CRUSH_TYPE}" in
    none)
      log_success "Disable changing crush rule automatically."
      ;;
    space)
      crush_type_space
      ;;
    safety)
      crush_type_safety
      ;;
    *)
      log "WARN- Definition of CRUSH_TYPE error. Do nothing."
      log "WARN- Disable changing crush rule automatically."
      log "WARN- CRUSH_TYPE: [ none | space | safety ]."
      ;;
  esac

  log "Removing lock for ${HOSTNAME}"
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/osd_crush_lock &>/dev/null || true
}

# auto change pg & crush leaf. Max replications is 2.
function crush_type_space {
  # RCs not greater than 2
  if [ "${NODEs}" -eq "0" ]; then
    log "WARN- No Storage Node, do nothing with changing crush_type"
    return 0
  elif [ "${NODEs}" -eq "1" ]; then
    set_pool_size 1 "${CURRENT_POOLS}"
    set_crush_ruleset osd "${CURRENT_POOLS}"
  else
    set_pool_size 2 "${CURRENT_POOLS}"
    set_crush_ruleset host "${CURRENT_POOLS}"
  fi

  # multiple = OSDs / 2, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr "${OSDs}" '+' 1)
  local multiple=$(expr "${prefix_multiple}" '/' 2)
  if [ "${multiple}" -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr "${PGs_PER_OSD}" '*' "${multiple}")
  set_pg_num "${RBD_POOL}" "${PG_NUM}"
}

# auto change pg & crush leaf. Max replications is 3.
function crush_type_safety {
  # RCs not greater than 3
  if [ "${NODEs}" -eq "0" ]; then
    log "WARN- No Storage Node, do nothing with changing crush_type"
    return 0
  elif [ "${NODEs}" -lt "3" ]; then
    set_pool_size "${NODEs}" "${CURRENT_POOLS}"
    set_crush_ruleset osd "${CURRENT_POOLS}"
  else
    set_pool_size 3 "${CURRENT_POOLS}"
    set_crush_ruleset host "${CURRENT_POOLS}"
  fi

  # multiple = OSDs / 3, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr "${OSDs}" '+' 1)
  local multiple=$(expr "${prefix_multiple}" '/' 3)
  if [ "${multiple}" -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr "${PGs_PER_OSD}" '*' "${multiple}")
  set_pg_num "${RBD_POOL}" "${PG_NUM}"
}

function set_crush_ruleset {
  # $1 = crush_ruleset {osd|host}, $2- = pool_name
  local CRUSH_RULE="$1"
  shift
  local POOL_NAME="$*"
  case "${CRUSH_RULE}" in
    host)
      local CRUSH_RULESET=0
      ;;
    osd)
      local CRUSH_RULESET=1
      ;;
    *)
      log "WARN- CRUSH_RULE ${CRUSH_RULE} not defined."
      return 0
      ;;
  esac

  for pool in ${POOL_NAME}; do
    if ceph "${CLI_OPTS[@]}" osd pool set "${pool}" crush_ruleset "${CRUSH_RULESET}" &>/dev/null; then
      log "Set pool ${pool} crush_ruleset to ${CRUSH_RULE}"
    else
      log "Fail to set crush_ruleset of ${pool} pool"
    fi
  done
}

function set_pool_size {
  # $1 = pool_size, $2 = pool_name
  local POOL_SIZE="$1"
  shift
  local POOL_NAME="$*"
  for pool in ${POOL_NAME}; do
    log "Set pool ${pool} replications to ${POOL_SIZE}"
    if ! ceph "${CLI_OPTS[@]}" osd pool set "${pool}" size "${POOL_SIZE}" 2>/dev/null; then
      log "WARN- Fail to set replications of ${pool} pool"
    fi
  done
}

function set_pg_num {
  # $1 = pool_name, $2 = pg_num
  log "Set pool $1 pg_num to $2"
  if ! ceph "${CLI_OPTS[@]}" osd pool set "$1" pg_num "$2" 2>/dev/null; then
    log "WARN- Fail to set pg_num of $1 pool"
    return 0
  fi

  # wait for pg_num resized and change pgp_num
  until [ $(ceph "${CLI_OPTS[@]}" -s | grep -c creating) -eq 0 ]; do
    sleep 5
  done
  if ! ceph "${CLI_OPTS[@]}" osd pool set "$1" pgp_num "$2" 2>/dev/null; then
    log "Fail to Set pgp_num of $1 pool"
    return 0
  fi
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
