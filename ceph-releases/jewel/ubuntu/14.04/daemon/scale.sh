#!/bin/bash

declare -r LOG_DEFAULT_COLOR="\033[0m"
declare -r LOG_ERROR_COLOR="\033[1;31m"
declare -r LOG_INFO_COLOR="\033[1m"
declare -r LOG_SUCCESS_COLOR="\033[1;32m"
declare -r LOG_WARN_COLOR="\033[1;35m"

function log() {
  local log_text="$1"
  local log_level="$2"
  local log_color="$3"

  # Default level to "info"
  [[ -z ${log_level} ]] && log_level="INFO";
  [[ -z ${log_color} ]] && log_color="${LOG_INFO_COLOR}";

  echo -e "${log_color}[$(date +"%Y-%m-%d %H:%M:%S")] [${log_level}] ${log_text} ${LOG_DEFAULT_COLOR}";
  return 0;
}

function log_info() { log "$@"; }
function log_success() { log "$1" "SUCCESS" "${LOG_SUCCESS_COLOR}"; }
function log_err() { log "$1" "ERROR" "${LOG_ERROR_COLOR}"; }
function err_status() { log "$1" "ERROR & WAIT" "${LOG_ERROR_COLOR}"; echo "$1" >/status; /usr/bin/tail -f /dev/null; }
function success_status() { echo "$1" >/status; }
function log_warn() { log "$1" "WARN" "${LOG_WARN_COLOR}"; }

function ceph_api () {
  case $1 in
    start_all_osds|set_max_osd|get_max_osd|stop_all_osds|stop_all_osds|get_active_osd_nums|run_osds)
      osd_controller_env
      $@
      ;;
    set_max_mon|get_max_mon|remove_mon)
      mon_controller_env
      $@
      ;;
    get_osd_map)
      $@
      ;;
    *)
      log_warn "Usahe: "
      ;;
  esac
}

function check_mon {
  CLUSTER_PATH=ceph-config/${CLUSTER}
  : ${K8S_IP:=${KV_IP}}
  : ${K8S_PORT:=8080}
  : ${MON_RECOVERY_LABEL:="cdxvirt/recovery"}
  check_single_mon
}

function check_single_mon {
  # if MON has single_mon kubernetes label then enter single mode
  if kubectl get node --show-labels --server=${K8S_IP}:${K8S_PORT} | grep -w "${K8S_IP}" | grep -w "${MON_RECOVERY_LABEL}=true" >/dev/null; then
    ceph-mon -i ${MON_NAME} --extract-monmap /tmp/monmap

    # remove all monmap list then add itself
    local MONMAP_LIST=$(monmaptool -p /tmp/monmap | awk '/mon\./ { sub ("mon.", "", $3); print $3}')
    for del_mon in ${MONMAP_LIST}; do
      monmaptool --rm $del_mon /tmp/monmap
    done
    monmaptool --add ${MON_NAME} ${MON_IP}:6789 /tmp/monmap
    ceph-mon -i ${MON_NAME} --inject-monmap /tmp/monmap
    kubectl label node --server=${K8S_IP}:${K8S_PORT} ${K8S_IP} ${MON_RECOVERY_LABEL}-
    rm /tmp/monmap
  fi
}

function mon_controller_env () {
  CLUSTER_PATH=ceph-config/${CLUSTER}
  : ${K8S_IP:=https://${KUBERNETES_SERVICE_HOST}}
  : ${K8S_PORT:=${KUBERNETES_SERVICE_PORT}}
  : ${K8S_CERT:="--certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"}
  : ${NAMESPACE:=ceph}
  : ${POD_SELECTOR:="ceph-mon"}
  : ${EP_NAME:="ceph-mon"}
  : ${MON_LABEL:="cdxvirt/ceph_mon"}
}

function mon_controller () {
  mon_controller_env
  # making sure the root dirs are present
  : ${MAX_MONS:=3}
  etcdctl -C ${KV_IP}:${KV_PORT} mkdir ${CLUSTER_PATH} > /dev/null 2>&1 || true
  etcdctl -C ${KV_IP}:${KV_PORT} mkdir ${CLUSTER_PATH}/mon_host > /dev/null 2>&1  || true
  set_max_mon ${MAX_MONS} init

  # if svc & ep is running, than set mon_host
  if kubectl get ep ${EP_NAME} --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} --namespace=${NAMESPACE} &>/dev/null; then
    etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/global/mon_host ${EP_NAME}.${NAMESPACE}
  fi

  while [ true ]; do
    mon_controller_main
    sleep 60
  done
}

function mon_controller_main () {
  # get $MAX_MONS & check it matching positive number
  re="^[1-9][0-9]*$"
  if MAX_MONS=$(etcdctl -C ${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/max_mons); then
    if ! [[ "${MAX_MONS}" =~ $re ]]; then
      log_err "MAX_MONS type error: ${MAX_MONS}"
      return 0
    fi
  else
    log_err "Can't read max_mons"
  fi

  get_mon_nodes

  # how many mons needs to add?
  current_mons=$(echo ${nodes_have_mon_label} | wc -w)
  if [ ${current_mons} -lt "${MAX_MONS}" ]; then
    local mon_num2add=$(expr ${MAX_MONS} - ${current_mons})
  elif [ ${current_mons} -gt "${MAX_MONS}" ]; then
    local mon_num2add="-1"
  else
    local mon_num2add=0
  fi

  # create kubernetes mon label
  local counter=0
  if [ ${mon_num2add} == "-1" ]; then
    auto_remove_mon
  else
    local counter=0
    for mon2add in ${nodes_no_mon_label}; do
      if [ "${counter}" -lt ${mon_num2add} ]; then
        kubectl label node --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} ${mon2add} \
          ${MON_LABEL}=true --overwrite &>/dev/null && log_success "Add Mon node \"${mon2add}\""
        let counter=counter+1
      fi
    done
  fi

  # update endpoints
  if kubectl get ep ${EP_NAME} --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} --namespace=${NAMESPACE} &>/dev/null; then
    update_ceph_mon_ep
  fi
}

function get_mon_nodes () {
  nodes_have_mon_label=$(kubectl get node --show-labels --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} \
    |  grep -w "${MON_LABEL}" | awk '/Ready/ { print $1 }')
  nodes_no_mon_label=$(kubectl get node --show-labels --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} \
    |  grep -wv "${MON_LABEL}" | awk '/Ready/ { print $1 }')
  etcd_mon_host=$(etcdctl -C ${KV_IP}:${KV_PORT} ls ${CLUSTER_PATH}/mon_host | sed "s#.*/mon_host/##")
}

function update_ceph_mon_ep () {
  local ep_list=""
  for mon_name in $(echo ${etcd_mon_host}); do
    local mon_ip=$(mon_name_2_mon_ip ${mon_name})
    # josn form needs ","
    if [ -z "${mon_ip}" ]; then
      log_warn "Can't get mon_ip from ${mon_name}"
    elif [ -z "${ep_list}" ]; then
      local mon_ip_ep_format="{\"ip\": \"${mon_ip}\"}"
      ep_list=${mon_ip_ep_format}
    else
      local mon_ip_ep_format="{\"ip\": \"${mon_ip}\"}"
      ep_list="${ep_list}, ${mon_ip_ep_format}"
    fi
  done

  # make sure ep_list is not null
  if [ -n "${ep_list}" ]; then
    local UPDATE_EP="kubectl --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} \
       --namespace=${NAMESPACE} patch ep ${EP_NAME} -p \
      '{\"subsets\": [{\"addresses\": [${ep_list}],\"ports\": [{\"port\": 6789,\"protocol\": \"TCP\"}]}]}'"
    eval $UPDATE_EP >/dev/null
  fi
}

function node_ip_2_pod_name () {
  if [ -z $1 ]; then
    log_err "Usage: node_ip_2_pod_name kubernetes_IP"
    exit 1
  fi
  kubectl get pod -o wide --namespace=${NAMESPACE} -l name=${POD_SELECTOR} | grep -w "$1" | awk '{ print $1 }'
}

function node_ip_2_hostname () {
  if [ -z $1 ]; then
    log_err "Usage: node_ip_2_hostname kubernetes_IP"
    exit 1
  fi
  local pod_name=$(node_ip_2_pod_name $1)
  kubectl exec --namespace=${NAMESPACE} ${pod_name} hostname 2>/dev/null
}

function mon_name_2_mon_ip () {
  if [ -z $1 ]; then
    log_err "Usage: mon_name_2_mon_ip mon_name"
    exit 1
  fi
  etcdctl -C ${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/mon_host/$1 2>/dev/null | sed 's/:6789//'
}

function remove_mon () {
  if [ -z $1 ]; then
    log_err "Usage: remove_mon MON_name"
    exit 1
  fi
  start_config
  get_mon_nodes
  if [ $(echo ${etcd_mon_host} | wc -w) -le $(get_max_mon) ]; then
    log_warn "Running Mon pods equals MAX_MONS. Do nothing."
    return 0
  fi
  for mon_node in ${nodes_have_mon_label}; do
    local mon_name=$(node_ip_2_hostname ${mon_node})
    if [ "$1" == "${mon_name}" ]; then
      etcdctl -C ${KV_IP}:${KV_PORT} rm ${CLUSTER_PATH}/mon_host/${mon_name} &>/dev/null || true
      kubectl label node --server=${K8S_IP}:${K8S_PORT} ${K8S_CERT} ${mon_node} \
        ${MON_LABEL}- &>/dev/null
      ceph mon remove "${mon_name}" || true
    fi
  done
  until confd -onetime -backend ${KV_TYPE} -node ${CONFD_NODE_SCHEMA}${KV_IP}:${KV_PORT} ${CONFD_KV_TLS} -prefix="/${CLUSTER_PATH}/" ; do
    echo "Waiting for confd to update templates..."
    sleep 1
  done
}

function auto_remove_mon () {
  start_config

  # get the last mon quorum index
  local mon_count=$(ceph quorum_status | jq .quorum | sed '1d;$d' | wc -w)
  local mon_quorum_json_index=$(expr ${mon_count} - 1)
  local mon_name2remove=$(ceph quorum_status | jq .quorum_names[${mon_quorum_json_index}] | tr -d "\"")
  if [ -z ${mon_name2remove} ]; then
    log_err "Monitor name not found"
    return 0
  elif [ "${mon_count}" -le 2 ]; then
    log_warn "Monitor number is too low. (Only \"${mon_count}\" monitor)"
    return 0
  else
    remove_mon ${mon_name2remove}
  fi
}

function set_max_mon () {
  if [ $# -eq "2" ] && [ $2 == "init" ]; then
    local max_mon_num=$1
    etcdctl -C ${KV_IP}:${KV_PORT} mk ${CLUSTER_PATH}/max_mons ${max_mon_num} &>/dev/null || true
    return 0
  elif [ -z "$1" ]; then
    log_err "Usage: set_max_mon 1~5+"
    exit 1
  else
    local max_mon_num=$1
  fi
  if etcdctl -C ${KV_IP}:${KV_PORT} set ${CLUSTER_PATH}/max_mons ${max_mon_num}; then
    log_success "Expect MON number is \"$1\"."
  else
    log_err "Fail to set \$MAX_MONS"
    return 1
  fi
}

function get_max_mon () {
  local MAX_MONS=""
  if MAX_MONS=$(etcdctl -C ${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/max_mons); then
    echo "${MAX_MONS}"
  else
    log_err "Fail to get \$MAX_MONS"
    return 1
  fi
}

function crush_initialization () {
  CLUSTER_PATH=ceph-config/${CLUSTER}

  # DO NOT EDIT DEFAULT POOL
  DEFAULT_POOL=rbd

  # Default crush leaf [ osd | host ] & replication size 1 ~ 9
  : ${DEFAULT_CRUSH_LEAF:=osd}
  : ${DEFAULT_POOL_COPIES:=1}

  # check ceph command is usable
  until timeout 10 ceph health &>/dev/null; do
    log_warn "Waitiing for ceph cluster is ready."
  done

  # set lock to avoid multiple node writting together
  until etcdctl -C ${KV_IP}:${KV_PORT} mk ${CLUSTER_PATH}/osd_init_lock ${HOSTNAME} > /dev/null 2>&1; do
    local LOCKER_NAME=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/osd_init_lock)
    if [[ ${LOCKER_NAME} == ${HOSTNAME} ]]; then
      log_warn "Last time Crush Initialization is locked by ${HOSTNAME} itself."
      break
    else
      log_warn "Crush Initialization is locked by ${LOCKER_NAME}. Waiting..."
      sleep 3
    fi
  done

  # check complete status
  if kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/initialization_complete > /dev/null 2>&1 ; then
    log_success "We detected a complete status, no need to initialize."
  else

    # initialization of crushmap
    log_info "Initialization of crushmap"
    # create a crush rule, chooseleaf as osd.
    ceph ${CEPH_OPTS} osd crush rule create-simple replicated_type_osd default osd firstn

    # crush_ruleset 0 for host, 1 for osd
    case "${DEFAULT_CRUSH_LEAF}" in
      host)
        ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 0
        ;;
      osd)
        ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 1
        ;;
      *)
        log_warn "DEFAULT_CRUSH_LEAF not in [ osd | host ], do nothing"
        ;;
    esac

    # Replication size of rbd pool
    # check size in the range 1 ~ 9
    local re='^[1-9]$'

    if ! [[ ${DEFAULT_POOL_COPIES} =~ ${re} ]]; then
      local size_defined_on_etcd=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/global/osd_pool_default_size)
      ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size ${size_defined_on_etcd}
      log_warn "DEFAULT_POOL_COPIES is not in the range 1 ~ 9, using default value ${size_defined_on_etcd}"
    else
      ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size ${DEFAULT_POOL_COPIES}
    fi

    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} put ${CLUSTER_PATH}/initialization_complete true > /dev/null 2>&1
  fi

  log_info "Removing lock for ${HOSTNAME}"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} del ${CLUSTER_PATH}/osd_init_lock > /dev/null 2>&1

}

function auto_change_crush () {
  # DO NOT EDIT DEFAULT POOL
  DEFAULT_POOL=rbd
  : ${CRUSH_TYPE:=space}
  : ${PGs_PER_OSD:=64}

  # If there are no osds, We don't change pg_num
  health_log=$(timeout 10 ceph health 2>/dev/null)
  if echo ${health_log} | grep -q "no osds"; then
    return 0
  fi

  # set lock to avoid multiple node writting together
  until etcdctl -C ${KV_IP}:${KV_PORT} mk ${CLUSTER_PATH}/osd_crush_lock ${HOSTNAME} > /dev/null 2>&1; do
    local LOCKER_NAME=$(kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} get ${CLUSTER_PATH}/osd_crush_lock)
    if [[ ${LOCKER_NAME} == ${HOSTNAME} ]]; then
      log_warn "Last time auto_change_crush is locked by ${HOSTNAME} itself."
      break
    else
      log_warn "Auto_change_crush is locked by ${LOCKER_NAME}. Waiting..."
      sleep 10
    fi
  done

  # NODES not include some host weight=0
  NODEs=$(ceph ${CEPH_OPTS} osd tree | awk '/host/ { print $2 }' | grep -v ^0$ -c || true)
  # Only count OSD that status is up
  OSDs=$(ceph ${CEPH_OPTS} osd stat | awk '{ print $5 }')
  # Put crush type into ETCD
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} put ${CLUSTER_PATH}/crush_type ${CRUSH_TYPE} >/dev/null 2>&1

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
      log_warn "Definition of CRUSH_TYPE error. Do nothing."
      log_warn "Disable changing crush rule automatically."
      log_warn "CRUSH_TYPE: [ none | space | safety ]."
      ;;
  esac

  log_info "Removing lock for ${HOSTNAME}"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} del ${CLUSTER_PATH}/osd_crush_lock > /dev/null 2>&1
}

# auto change pg & crush leaf. Max replications is 2.
function crush_type_space () {
  # RCs not greater than 2
  if [ ${NODEs} -eq "0" ]; then
    log_warn "No Storage Node, do nothing with changing crush_type"
    return 0
  elif [ ${NODEs} -eq "1" ]; then
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size 1
  else
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size 2
  fi

  # multiple = OSDs / 2, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr ${OSDs} '+' 1)
  local multiple=$(expr ${prefix_multiple} '/' 2)
  if [ ${multiple} -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr ${PGs_PER_OSD} '*' ${multiple})
  set_pg_num ${DEFAULT_POOL} ${PG_NUM}
  auto_change_crush_leaf 2
}

# auto change pg & crush leaf. Max replications is 3.
function crush_type_safety () {
  # RCs not greater than 3
  if [ ${NODEs} -eq "0" ]; then
    log_warn "No Storage Node, do nothing with changing crush_type"
    return 0
  elif [ ${NODEs} -lt "3" ]; then
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size ${NODEs}
  else
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} size 3
  fi

  # multiple = OSDs / 3, pg_num = PGs_PER_OSD x multiple
  local prefix_multiple=$(expr ${OSDs} '+' 1)
  local multiple=$(expr ${prefix_multiple} '/' 3)
  if [ ${multiple} -lt "1" ]; then
    local multiple=1
  fi
  local PG_NUM=$(expr ${PGs_PER_OSD} '*' ${multiple})
  set_pg_num ${DEFAULT_POOL} ${PG_NUM}
  auto_change_crush_leaf 2
}

# usage: auto_change_crush_leaf ${MAX_COPIES}
function auto_change_crush_leaf () {
  # crush_ruleset 0 for host, 1 for osd
  if [ ${NODEs} -ge $1 ]; then
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 0
  else
    ceph ${CEPH_OPTS} osd pool set ${DEFAULT_POOL} crush_ruleset 1
  fi
}

function set_pg_num () {
  # $1 = pool_name, $2 = pg_num
   if ! ceph ${CEPH_OPTS} osd pool set $1 pg_num $2; then
     log_warn "Fail to Set pg_num of $1 pool"
     return 0
   fi

  # wait for pg_num resized and change pgp_num
  until [ $(ceph ${CEPH_OPTS} -s | grep creating -c) -eq 0 ]; do
    sleep 5
  done
  if ! ceph ${CEPH_OPTS} osd pool set $1 pgp_num $2; then
    log_warn "Fail to Set pgp_num of $1 pool"
    return 0
  fi
}

# setup/check require option and tool
function osd_controller_env () {
  : ${CLUSTER_PATH:=ceph-config/${CLUSTER}}
  : ${OSD_INIT_MODE:=minimal}
  : ${MAX_OSDS:=1}
  command -v docker > /dev/null 2>&1 || { echo "Command not found: docker"; exit 1; }
  DOCKER_CMD=$(command -v docker)
  DOCKER_VERSION=$($DOCKER_CMD -v | awk  /Docker\ version\ /'{print $3}')
  # check docker version
  if ! [[ -n "${DOCKER_VERSION}" ]]; then
    $DOCKER_CMD -v
    exit 1
  fi

  : ${OSD_FOLDER:="/var/lib/ceph/osd"}
  mkdir -p ${OSD_FOLDER}
  chown ceph. ${OSD_FOLDER}
  if [ -n "${OSD_MEM}" ]; then OSD_MEM="-m ${OSD_MEM}"; fi
  if [ -n "${OSD_CPU_CORE}" ]; then OSD_CPU_CORE="-c ${OSD_CPU_CORE}"; fi
  set_max_osd ${MAX_OSDS} init
}

function run_osds () {
  start_all_osds
  add_new_osd auto
  auto_change_crush
}

function start_all_osds () {
  # get all avail disks
  local DISKS=$(get_avail_disks)

  if [ -z "${DISKS}" ]; then
    log_err "No available disk"
    return 0
  fi

  for disk in ${DISKS}; do
    if [ "$(is_osd_disk ${disk})" == "true" ]; then
      activate_osd $disk
    fi
  done
}

function activate_osd () {
  if [ -z "$1" ]; then
    log_err "activate_osd () need to assign a OSD."
    return 1
  else
    local disk2act=$1
  fi

  # if OSD is running or come from another cluster, then return 0.
  if is_osd_running ${disk2act}; then
    local CONT_ID=$(${DOCKER_CMD} ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME=${disk2act})
    log_success "${disk2act} is running as OSD (${CONT_ID})."
    return 0
  elif ! is_osd_correct ${disk2act}; then
    log_warn "The OSD disk ${disk2act} unable to activate for current Ceph cluster."
    return 0
  fi

  local CONT_NAME=$(create_cont_name ${disk2act} ${OSD_ID})
  if $DOCKER_CMD inspect ${CONT_NAME} &>/dev/null; then
    $DOCKER_CMD rm ${CONT_NAME} >/dev/null
  fi

  # XXX: auto find DAEMON_VERSION
  $DOCKER_CMD run -d -l CLUSTER=${CLUSTER} -l CEPH=osd -l DEV_NAME=${disk2act} -l OSD_ID=${OSD_ID} \
    --name=${CONT_NAME} --privileged=true --net=host --pid=host -v /dev:/dev ${OSD_MEM} ${OSD_CPU_CORE} \
    -e KV_TYPE=${KV_TYPE} -e KV_PORT=${KV_PORT} -e DEBUG_MODE=${DEBUG_MODE} -e OSD_DEVICE=${disk2act} \
    -e OSD_TYPE=activate ${DAEMON_VERSION} osd >/dev/null

  # XXX: check OSD container status continuously
  sleep 3
  if is_osd_running ${disk2act}; then
    local CONT_ID=$(${DOCKER_CMD} ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME=${disk2act})
    log_success "Success to activate ${disk2act} (${CONT_ID})."
  fi
}

function add_new_osd () {
  # if $1 is null, then add one osd.
  if [ -z "$1" ]; then
    add_n=1
  elif [ "$1" == "auto" ]; then
    add_n=$(calc_osd2add)
  else
    add_n=$1
  fi

  # check add_n is natural number.
  re="^[0-9]+([.][0-9]+)?$"
  if ! [[ ${add_n} =~ $re ]]; then
    log_err "\${add_n} is not a natural number."
    return 1
  fi

  # find available disks.
  DISKS=""
  for disk in $(get_avail_disks); do
    if ! is_osd_running ${disk}; then
      DISKS="${DISKS} ${disk}"
    fi
  done
  if [ -z "${DISKS}" ]; then
    log_warn "No available disk for adding a new OSD."
    return 0
  fi

  # find disks not having OSD partitions.
  disks_without_osd=""
  for disk in ${DISKS}; do
    if [ "$(is_osd_disk ${disk})" == "false" ]; then
      disks_without_osd="${disks_without_osd} ${disk}"
    fi
  done

  osd_add_list=""
  # Three cases for selecting osd disks and print to $osd_add_list.
  case "${OSD_INIT_MODE}" in
    minimal)
      # Ignore OSD disks. But if No OSDs in cluster, force to choose one.
      if [ -n "${disks_without_osd}" ]; then
        select_n_disks "${disks_without_osd}" ${add_n}
      elif [ -z "${disks_without_osd}" ] && timeout 10 ceph health 2>/dev/null | grep -q "no osds"; then
        # TODO: Deploy storage PODs on two or more storage node concurrently,
        # every node will force to choose one and use it.
        # We hope only one disk in the cluster will be format.
        osd_add_list=$(echo ${DISKS} | awk '{print $1}')
      fi
      ;;
    force)
      # Force to select all disks
      select_n_disks "${DISKS}" ${add_n}
      ;;
    strict)
      # Ignore all OSD disks.
      select_n_disks "${disks_without_osd}" ${add_n}
      ;;
    *)
      ;;
  esac

  if [ -n "${osd_add_list}" ]; then
    # clear lvm & raid
    clear_lvs_disks
    clear_raid_disks
  else
    return 0
  fi

  for disk in ${osd_add_list}; do
    if ! prepare_new_osd ${disk}; then
      log_err "OSD ${disk} fail to prepare."
    elif ! activate_osd ${disk}; then
      log_err "OSD ${disk} fail to activate."
    fi
  done
}

function calc_osd2add () {
  if ! max_osd_num=$(etcdctl get ${CLUSTER_PATH}/max_osd_num_per_node); then
    max_osd_num=1
  fi

  if [ $(get_active_osd_nums) -ge "${max_osd_num}" ]; then
    echo "0"
  else
    local osd_num2add=$(expr ${max_osd_num} - $(get_active_osd_nums))
    echo ${osd_num2add}
  fi
}

function select_n_disks () {
  local counter=0
  for disk in $1; do
    if [ "${counter}" -lt "$2" ]; then
      osd_add_list="${osd_add_list} ${disk}"
      let counter=counter+1
    fi
  done
}

function prepare_new_osd () {
  if [ -z "$1" ]; then
    log_err "prepare_new_osd need to assign a disk."
    return 1
  else
    local osd2prep=$1
  fi
  local CONT_NAME="$(create_cont_name ${osd2prep})_prepare_$(date +%N)"
  sgdisk --zap-all --clear --mbrtogpt ${osd2prep}
  if $DOCKER_CMD run -l CLUSTER=${CLUSTER} -l CEPH=osd_prepare -l DEV_NAME=osd2prep --name=${CONT_NAME} \
    --privileged=true -v /dev/:/dev/ -e KV_PORT=2379 -e KV_TYPE=etcd -e OSD_TYPE=prepare \
    -e OSD_DEVICE=${osd2prep} -e OSD_FORCE_ZAP=1 ${DAEMON_VERSION} osd &>/dev/null; then
    return 0
  else
    return 1
  fi
}

function create_cont_name () {
  # usage: create_cont_name DEV_PATH OSD_ID, e.g. create_cont_name /dev/sda 12 => OSD_12_sda
  if [ $# -ne 2 ] && [ $# -ne 1 ]; then
    log_err "create_cont_name DEV_PATH OSD_ID"
    return 1
  fi
  if echo "$1" | grep -q "^/dev/"; then
    local SHORT_DEV_NAME=$(echo "$1" | sed 's/\/dev\///g')
  else
    local SHORT_DEV_NAME=""
  fi

  if [ -z "${SHORT_DEV_NAME}" ] && [ -z "$2" ]; then
    echo "OSD"
  elif [ -z "${SHORT_DEV_NAME}" ]; then
    echo "OSD_$2"
  elif [ -z "$2" ]; then
    echo "OSD_${SHORT_DEV_NAME}"
  else
    echo "OSD_$2_${SHORT_DEV_NAME}"
  fi
}

function set_max_osd () {
  if [ $# -eq "2" ] && [ $2 == "init" ]; then
    local max_osd_num=$1
    etcdctl mk ${CLUSTER_PATH}/max_osd_num_per_node ${max_osd_num} &>/dev/null || true
    return 0
  elif [ -z "$1" ]; then
    local max_osd_num=1
  else
    local max_osd_num=$1
  fi
  if etcdctl set ${CLUSTER_PATH}/max_osd_num_per_node ${max_osd_num}; then
    log_success "Expect OSD number per node is ${max_osd_num}."
  else
    log_err "Fail to set max_osd_num_per_node"
    return 1
  fi
}

function get_max_osd {
  local MAX_OSDS=""
  if MAX_OSDS=$(etcdctl get ${CLUSTER_PATH}/max_osd_num_per_node); then
    echo "${MAX_OSDS}"
  else
    log_err "Fail to get max_osd_num_per_node"
    return 1
  fi
}

function get_slot_mapping {
  if [ -z $1 ]; then
    return 0
  fi
  printf '%s\n' "$avail_devs" | while IFS= read -r line
  do
    echo $"$line"
  done | grep -w ^$1 | awk '{print $2}'
}

function get_dev_osdid {
  if [ -z $1 ]; then
    return 0
  fi
  local osd_cont_id=$(docker ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME="/dev/$1")
  if [ ! -z ${osd_cont_id} ]; then
    local osd_id=$(docker inspect --format='{{.Config.Labels.OSD_ID}}' "${osd_cont_id}" 2>/dev/null)
  else
    echo ""
    return 0
  fi
  re="^[0-9]+([.][0-9]+)?$"
  if [[ ${osd_id} =~ $re ]]; then
    echo ${osd_id}
  fi
}



function get_dev_model {
  if [ -z $1 ]; then
    return 0
  elif [ $(readlink -f /sys/class/block/$1| grep '/ata[0-9]*/') ]; then
    local ATA_PORT="$(readlink -f "/sys/class/block/$1" | sed -n "s/.*ata\([0-9]\{1,3\}\)\/host.*/\1/p")"
    local ID_FILE="/sys/class/ata_device/dev$ATA_PORT.0/id"
    local count="0"
    echo -n "0x"
    for i in `/bin/cat $ID_FILE`; do
        count=$(($count+1))
        if [ $count -gt 27 ] && [ $count -le 47 ];then
                echo -n `echo $i |/usr/bin/cut -c1-2`
                echo -n `echo $i |/usr/bin/cut -c3-4`
       fi
    done
  elif [ -f "/sys/class/block/$1/device/model" ]; then
    local dev_model=$(od -An -t x1 /sys/block/$1/device/model 2>/dev/null)
    declare -a a_model
    count="0"
    for i in $dev_model; do
       a_model[$count]=$(echo $i)
       count=$(($count+1))
    done
    len="16"
    count="0"
    echo -n "0x"
    for i in $(seq $len); do
       echo -n "${a_model[$count]}"
       count=$(($count+1))
    done
  fi
  return 0
}

function get_dev_serial {
  if [ -z $1 ]; then
    return 0
  elif [ $(readlink -f /sys/class/block/$1| grep '/ata[0-9]*/') ]; then
    local ATA_PORT="$(readlink -f "/sys/class/block/$1" | sed -n "s/.*ata\([0-9]\{1,3\}\)\/host.*/\1/p")"
    local ID_FILE="/sys/class/ata_device/dev$ATA_PORT.0/id"
    local count="0"
    echo -n "0x"
    for i in `/bin/cat $ID_FILE`; do
        count=$(($count+1))
        if [ $count -gt 10 ] && [ $count -le 20 ];then
        	echo -n `echo $i |/usr/bin/cut -c1-2`
          	echo -n `echo $i |/usr/bin/cut -c3-4`
       fi
    done
  elif [ -f "/sys/class/block/$1/device/vpd_pg80" ]; then
    pg80=$(od -An -t x1 /sys/block/$1/device/vpd_pg80)
    declare -a a_pg80
    local count="0"
    for i in $pg80; do
       a_pg80[$count]=$(echo $i)
       count=$(($count+1))
    done
    if [ ${a_pg80[1]} -eq "80" ]; then
       len=$(printf "%d" "0x${a_pg80[3]}")
       count="4"
       echo -n "0x"
       for i in $(seq $len); do
           echo -n "${a_pg80[$count]}"
           count=$(($count+1))
       done
    else
       echo "page format error"
       #exit 1
       return 0
    fi
  fi
  return 0
}

function get_dev_fwrev {
  if [ -z $1 ]; then
    return 0
  elif [ $(readlink -f /sys/class/block/$1| grep '/ata[0-9]*/') ]; then
    local ATA_PORT="$(readlink -f "/sys/class/block/$1" | sed -n "s/.*ata\([0-9]\{1,3\}\)\/host.*/\1/p")"
    local ID_FILE="/sys/class/ata_device/dev$ATA_PORT.0/id"
    local count="0"
    echo -n "0x"
    for i in `/bin/cat $ID_FILE`; do
        count=$(($count+1))
        if [ $count -gt 23 ] && [ $count -le 27 ];then
                echo -n `echo $i |/usr/bin/cut -c1-2`
                echo -n `echo $i |/usr/bin/cut -c3-4`
       fi
    done
  elif [ -f "/sys/class/block/$1/device/rev" ]; then
    local dev_fwrev=$(od -An -t x1 /sys/block/$1/device/rev 2>/dev/null)
    declare -a a_rev
    count="0"
    for i in $dev_fwrev; do
       a_rev[$count]=$(echo $i)
       count=$(($count+1))
    done
    len="4"
    count="0"
    echo -n "0x"
    for i in $(seq $len); do
       echo -n "${a_rev[$count]}"
       count=$(($count+1))
    done
  fi
  return 0
}



function get_osd_map {
  MAPPING_COMMAND="/opt/bin/mapping.sh"
  command -v ${MAPPING_COMMAND} &>/dev/null || { echo "Command not found: \"${MAPPING_COMMAND}\"";exit 1; }
  slot_list=$(${MAPPING_COMMAND} --list-all-slots)
  avail_devs=$(${MAPPING_COMMAND} --list-all-disk-mappings)

  # create json output
  # begin
  osd_map_json='{"node":['

  local counter=1
  local entries=$(echo $slot_list | wc -w)
  for slot in ${slot_list}; do
    dev_name=$(get_slot_mapping ${slot})
    osd_id=$(get_dev_osdid ${dev_name})
    disk_model=$(get_dev_model ${dev_name})
    disk_serial=$(get_dev_serial ${dev_name})
    disk_fwrev=$(get_dev_fwrev ${dev_name})
    osd_map_json=${osd_map_json}'{"slot":"'$slot'","dev_name":"'${dev_name}'","osd_id":"'${osd_id}'","disk_model":"'${disk_model}'","disk_serial":"'${disk_serial}'","disk_fwrev":"'${disk_fwrev}'"}'

    # add comma
    if [ ${counter} -lt ${entries} ]; then
      osd_map_json=${osd_map_json}','
    fi
    let counter=counter+1
  done
  osd_map_json=${osd_map_json}']}'
  echo ${osd_map_json}
}

function get_active_osd_nums () {
  ${DOCKER_CMD} ps -q -f LABEL=CEPH=osd | wc -l
}

function stop_all_osds () {
  ${DOCKER_CMD} stop $(${DOCKER_CMD} ps -q -f LABEL=CEPH=osd)
}

function restart_all_osds () {
  ${DOCKER_CMD} restart $(${DOCKER_CMD} ps -q -f LABEL=CEPH=osd)
}

function is_osd_running () {
  # give a disk and check OSD container
  if [ -z "$1" ]; then
    log_err "is_osd_running () need to assign a OSD."
    exit 1
  else
    local DEV_NAME=$1
  fi

  # check running & exited containers
  local CONT_ID=$(${DOCKER_CMD} ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME=${DEV_NAME})
  if [ -n "${CONT_ID}" ]; then
    return 0
  else
    return 1
  fi
}

function is_osd_correct() {
  if [ -z "$1" ]; then
    log_err "is_osd_correct () need to assign a OSD."
    exit 1
  else
    # FIXME: disk2verify is a variable ti find ceph data JOURNAL partition.
    disk2verify=$1
  fi

  disk2verify="${disk2verify}1"
  if ceph-disk --setuser ceph --setgroup disk activate ${disk2verify} &>/dev/null; then
    OSD_ID=$(df | grep "${disk2verify}" | sed "s/.*${CLUSTER}-//g")
    umount ${disk2verify}
    return 0
  else
    OSD_ID=""
    umount ${disk2verify} &>dev/null || true
    return 1
  fi
}

function is_osd_disk() {
  # Check label partition table includes "ceph journal" or not
  if ! sgdisk --verify $1 &>/dev/null; then
    echo "false"
  elif parted -s $1 print 2>/dev/null | egrep -sq '^ 1.*ceph data' ; then
    echo "true"
  else
    echo "false"
  fi
}

# Find disks not only unmounted but also non-ceph disks
function get_avail_disks () {
  BLOCKS=$(readlink /sys/class/block/* -e | grep -v "usb" | grep -o "sd[a-z]$")
  [[ -n "${BLOCKS}" ]] || ( echo "" ; return 1 )

  while read disk ; do
    # Double check it
    if ! lsblk /dev/${disk} > /dev/null 2>&1; then
      continue
    fi

    if [ -z "$(lsblk /dev/${disk} -no MOUNTPOINT)" ]; then
      # Find it
      echo "/dev/${disk}"
    fi
  done < <(echo "$BLOCKS")
}

function hotplug_OSD () {
  inotifywait -r -m /dev/ -e CREATE -e DELETE | while read dev_msg; do
    local hotplug_disk=$(echo $dev_msg | awk '{print $1$3}')
    local action=$(echo $dev_msg | awk '{print $2}')

    if [[ "${hotplug_disk}" =~ /dev/sd[a-z]$ ]]; then
      case "${action}" in
        CREATE)
          run_osds
          ;;
        DELETE)
          log_info "Remove ${hotplug_disk}"
          if is_osd_running ${hotplug_disk}; then
            local CONT_ID=$(${DOCKER_CMD} ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME=${hotplug_disk})
            ${DOCKER_CMD} stop ${CONT_ID} &>/dev/null || true
          fi
          ;;
        *)
          ;;
      esac
    fi
  done
}

# XXX: We suppose we don't need any lvs and raid disks at all and just delete them
function clear_lvs_disks () {
  lvs=$(lvscan | grep '/dev.*' | awk '{print $2}')

  if [ -n "$lvs" ]; then
    log_info "Find logic volumes, inactive them."
    for lv in $lvs
    do
      lvremove -f "${lv//\'/}"
    done

  fi

  vgs=$(vgdisplay -C --noheadings --separator '|' | cut -d '|' -f 1)
  if [ -n "$vgs" ]; then
    log_info "Find VGs, delete them."
    for vg in $vgs
    do
      vgremove -f "$vg"
    done

  fi


  pvs=$(pvscan -s | grep '/dev/sd[a-z].*' || true)
  if [ -n "$pvs" ]; then
    log_info "Find PVs, delete them."
    for pv in $pvs
    do
      pvremove -ff -y "$pv"
    done

  fi
}

function clear_raid_disks () {
  mds=$(mdadm --detail --scan  | awk '{print $2}')

  if [ -z "${mds}" ]; then
    # Nothing to do
    return 0
  fi

  for md in ${mds}
  do
    devs=$(mdadm --detail --export "${md}" | grep MD_DEVICE_.*_DEV | cut -d '=' -f 2)
    if [ -z "$devs" ]; then
      log_info "No invalid devices"
      return 1
    fi
    mdadm --stop ${md}

    for dev in ${devs}
    do
      log_info "Clear MD device: $dev"
      mdadm --wait --zero-superblock --force "$dev"
    done
  done
}

function docker(){
  local ARGS=""
  for ARG in "$@"; do
    if [[ -n "$(echo "${ARG}" | grep '{.*}' | jq . 2>/dev/null)" ]]; then
      ARGS="${ARGS} \"$(echo ${ARG} | jq -c . | sed "s/\"/\\\\\"/g")\""
    elif [[ "$(echo "${ARG}" | wc -l)" -gt "1" ]]; then
      ARGS="${ARGS} \"$(echo "${ARG}" | sed "s/\"/\\\\\"/g")\""
    else
      ARGS="${ARGS} ${ARG}"
    fi
  done
  [[ "${DEBUG}" == "true" ]] && set -x

  bash -c "LD_LIBRARY_PATH=/lib:/host/lib $(which docker) ${ARGS}"
}
