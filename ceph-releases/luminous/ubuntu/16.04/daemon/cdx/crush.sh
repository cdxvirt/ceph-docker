#!/bin/bash

##############
# CRUSH INIT #
##############

function crush_initialization {
  # DO NOT EDIT DEFAULT POOL
  DEFAULT_POOL=rbd

  # Default crush leaf [ osd | host ] & replication size 1 ~ 9
  : ${DEFAULT_CRUSH_LEAF:=osd}
  : ${DEFAULT_POOL_COPIES:=1}

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
    # since ceph-12, we need to make default pool by hand.
    ceph "${CLI_OPTS[@]}" osd pool create "${DEFAULT_POOL}" 32 &>/dev/null || true
    ceph "${CLI_OPTS[@]}" osd pool application enable "${DEFAULT_POOL}" rbd &>/dev/null || true
    # create a crush rule, chooseleaf as osd.
    ceph "${CLI_OPTS[@]}" osd crush rule create-simple replicated_type_osd default osd firstn
    # crush_ruleset host, osd
    set_crush_ruleset "${DEFAULT_POOL}" "${DEFAULT_CRUSH_LEAF}"
    # Replication size of rbd pool
    # check size in the range 1 ~ 9
    local re='^[1-9]$'
    if ! [[ "${DEFAULT_POOL_COPIES}" =~ "${re}" ]]; then
      local size_defined_on_etcd=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/global/osd_pool_default_size)
      ceph "${CLI_OPTS[@]}" osd pool set "${DEFAULT_POOL}" size "${size_defined_on_etcd}"
      log "WARN- DEFAULT_POOL_COPIES is not in the range 1 ~ 9, using default value ${size_defined_on_etcd}"
    else
      ceph "${CLI_OPTS[@]}" osd pool set "${DEFAULT_POOL}" size "${DEFAULT_POOL_COPIES}"
    fi
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
  DEFAULT_POOL=rbd
  # If there are no osds, We don't change pg_num
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
  OSDs=$(ceph "${CLI_OPTS[@]}" osd stat | awk '{ print $5 }')
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
    set_pool_size "${DEFAULT_POOL}" 1
    set_crush_ruleset "${DEFAULT_POOL}" osd
  else
    set_pool_size "${DEFAULT_POOL}" 2
    set_crush_ruleset "${DEFAULT_POOL}" host
  fi

  # multiple = OSDs / 2, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr "${OSDs}" '+' 1)
  local multiple=$(expr "${prefix_multiple}" '/' 2)
  if [ "${multiple}" -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr "${PGs_PER_OSD}" '*' "${multiple}")
  set_pg_num "${DEFAULT_POOL}" "${PG_NUM}"
}

# auto change pg & crush leaf. Max replications is 3.
function crush_type_safety {
  # RCs not greater than 3
  if [ "${NODEs}" -eq "0" ]; then
    log "WARN- No Storage Node, do nothing with changing crush_type"
    return 0
  elif [ "${NODEs}" -lt "3" ]; then
    set_pool_size "${DEFAULT_POOL}" "${NODEs}"
    set_crush_ruleset "${DEFAULT_POOL}" osd
  else
    set_pool_size "${DEFAULT_POOL}" 3
    set_crush_ruleset "${DEFAULT_POOL}" host
  fi

  # multiple = OSDs / 3, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr "${OSDs}" '+' 1)
  local multiple=$(expr "${prefix_multiple}" '/' 3)
  if [ "${multiple}" -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr "${PGs_PER_OSD}" '*' "${multiple}")
  set_pg_num "${DEFAULT_POOL}" "${PG_NUM}"
}

function set_crush_ruleset {
  # $1 = pool_name $2 = crush_ruleset {osd|host}
  local POOL_NAME="$1"
  local CRUSH_RULE="$2"
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

  if ceph "${CLI_OPTS[@]}" osd pool set "${POOL_NAME}" crush_ruleset "${CRUSH_RULESET}" &>/dev/null; then
    log "Set pool $1 crush_ruleset to ${CRUSH_RULE}"
  else
    log "Fail to set crush_ruleset of $1 pool"
    return 0
  fi
}

function set_pool_size {
  # $1 = pool_name $2 = pool_size
  log "Set pool $1 replications to $2"
  if ! ceph "${CLI_OPTS[@]}" osd pool set "$1" size "$2" 2>/dev/null; then
    log "WARN- Fail to set replications of $1 pool"
    return 0
  fi
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

