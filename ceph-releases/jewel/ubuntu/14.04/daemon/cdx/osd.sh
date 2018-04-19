#!/bin/bash

source cdx/crush.sh
source cdx/osd-api.sh
source cdx/osd-verify.sh

function check_init_cdx_osd {
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "${CLUSTER_PATH}"/max_osd "${MAX_OSD}" &>/dev/null || true
  ceph "${CLI_OPTS[@]}" osd crush add-bucket "${HOSTNAME}" host &>/dev/null
  # XXX: need more flexiable
  ceph "${CLI_OPTS[@]}" osd crush move "${HOSTNAME}" root=default &>/dev/null

  check_osd_env
}

function check_osd_env {
  # MEM & CPU cores of OSD container
  if [ -n "${OSD_MEM}" ]; then
    OSD_MEM=(-m ${OSD_MEM})
  else
    OSD_MEM=()
  fi
  if [ -n "${OSD_CPU_CORE}" ]; then
    OSD_CPU_CORE=(-c ${OSD_CPU_CORE})
  else
    OSD_CPU_CORE=()
  fi

  # check docker command

  DOCKER_CMD=docker
  if ! "${DOCKER_CMD}" -v | grep -wq "version"; then
    "${DOCKER_CMD}" -v
    exit 1
  fi

  # find container image DAEMON_VERSION
  CDX_OSD_CONT_ID=$(basename "$(cat /proc/1/cpuset)")
  DAEMON_VERSION=$(${DOCKER_CMD} inspect -f '{{.Config.Image}}' ${CDX_OSD_CONT_ID})
}

function docker {
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
  bash -c "LD_LIBRARY_PATH=/lib:/host/lib $(which docker) ${ARGS}"
}

function cdx_osd {
  get_ceph_admin
  crush_initialization
  check_init_cdx_osd
  run_osds

  log "Start ETCD watcher."
  /bin/bash -c "/bin/bash /cdx/etcd-watcher.sh init" &

  log "Loop & check hotplug OSDs."
  hotplug_OSD
}

function run_osds {
  start_all_osds
  add_new_osd
  auto_change_crush
}

function get_active_osd_nums {
  "${DOCKER_CMD}" ps -q -f LABEL=CEPH=osd | wc -l
}

function start_all_osds {
  # get all avail disks
  local DISK_LIST=$(get_avail_disks)

  if [ -z "${DISK_LIST}" ]; then
    log "ERROR- No available disk."
    return 0
  fi

  log "Start all OSDs."
  for disk in ${DISK_LIST}; do
    activate_osd "${disk}" &>/dev/null &
  done
  wait
}

function activate_osd {
  if [ -z "$1" ]; then
    log "ERROR- Function activate_osd need to assign a DISK."
    return 1
  else
    local disk2act="$1"
  fi

  # if OSD is running  then return.
  if is_osd_running "${disk2act}"; then
    local CONT_ID=$("${DOCKER_CMD}" ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME=${disk2act})
    log "${disk2act} is running as OSD (${CONT_ID})."
    return 0
  fi

  # verify and get OSD
  local OSD_ID=$(verify_osd ${disk2act})
  case ${OSD_ID} in
    [[:digit:]]*|OSD)
      ;;
    *)
      log "WARN- The OSD disk ${disk2act} unable to activate for current Ceph cluster."
      return 3
      ;;
  esac

  # Remove the old OSD container
  local CONT_NAME=$(create_cont_name "${disk2act}" "${OSD_ID}")
  if "$DOCKER_CMD" inspect "${CONT_NAME}" &>/dev/null; then
    "$DOCKER_CMD" rm "${CONT_NAME}" >/dev/null
  fi

  # Ready to activate
  if is_disk_ssd "${disk2act}"; then
    "$DOCKER_CMD" run -d -l CLUSTER="${CLUSTER}" -l CEPH=osd -l DEV_NAME="${disk2act}" -l OSD_ID="${OSD_ID}" \
      --name="${CONT_NAME}" --privileged=true --net=host --pid=host -v /dev:/dev "${OSD_MEM[@]}" "${OSD_CPU_CORE[@]}" \
      -e CDX_ENV="${CDX_ENV}" -e DEBUG="${DEBUG}" -e OSD_DEVICE="${disk2act}" -e CRUSH_LOCATION=\"root=SSD host=${HOSTNAME}-SSD\" \
      "${DAEMON_VERSION}" osd_ceph_disk_activate >/dev/null
  else
    "$DOCKER_CMD" run -d -l CLUSTER="${CLUSTER}" -l CEPH=osd -l DEV_NAME="${disk2act}" -l OSD_ID="${OSD_ID}" \
      --name="${CONT_NAME}" --privileged=true --net=host --pid=host -v /dev:/dev "${OSD_MEM[@]}" "${OSD_CPU_CORE[@]}" \
      -e CDX_ENV="${CDX_ENV}" -e DEBUG="${DEBUG}" -e OSD_DEVICE="${disk2act}" \
      "${DAEMON_VERSION}" osd_ceph_disk_activate >/dev/null
  fi

  # XXX: check OSD container status continuously
  sleep 3
  if is_osd_running "${disk2act}"; then
    local CONT_ID=$("${DOCKER_CMD}" ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME="${disk2act}")
    log "Success to activate ${disk2act} (${CONT_ID})."
  else
    local CONT_ID=$("${DOCKER_CMD}" ps -a -l -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME="${disk2act}")
    log "WARN- Failed to activate ${disk2act} (${CONT_ID})."
  fi
}

function add_new_osd {
  # if $1 is null, then auto add.
  if [ -z "$1" ]; then
    add_n=$(calc_osd2add)
  elif natural_num "$1"; then
    add_n="$1"
  else
    log "ERROR- add_new_osd needs a natural number."
  fi

  # find available disks.
  local DISK_LIST=$(get_avail_disks)
  local AVAL_DISK=""
  for disk in ${DISK_LIST}; do
    if ! is_osd_running "${disk}"; then
      AVAL_DISK="${AVAL_DISK} ${disk}"
    fi
  done
  if [ -z "${AVAL_DISK}" ]; then
    log "WARN- No available disk for adding a new OSD."
    return 0
  fi

  # find disks having no OSD partitions.
  local NOT_OSD_DISK=""
  for disk in ${AVAL_DISK}; do
    if ! is_osd_disk "${disk}"; then
      NOT_OSD_DISK="${NOT_OSD_DISK} ${disk}"
    fi
  done

  # $OSD_ADD_LIST will call by select_n_disks ().
  OSD_ADD_LIST=""
  # Three cases for selecting osd disks and print to $OSD_ADD_LIST.
  case "${OSD_INIT_MODE}" in
    minimal)
      # Ignore OSD disks. But if No OSDs in cluster, force to choose one.
      if [ -n "${NOT_OSD_DISK}" ]; then
        select_n_disks "${NOT_OSD_DISK}" "${add_n}"
      elif [ -z "${NOT_OSD_DISK}" ] && timeout 10 ceph "${CLI_OPTS[@]}" health 2>/dev/null | grep -q "no osds"; then
        # TODO: Deploy storage PODs on two or more storage node concurrently,
        # every node will force to choose one and use it.
        # We hope only one disk in the cluster will be format.
        OSD_ADD_LIST=$(echo "${AVAL_DISK}" | awk '{print $1}')
      fi
      ;;
    force)
      # Force to select all disks
      select_n_disks "${AVAL_DISK}" "${add_n}"
      ;;
    strict)
      # Ignore all OSD disks.
      select_n_disks "${NOT_OSD_DISK}" "${add_n}"
      ;;
    *)
      ;;
  esac

  for disk in ${OSD_ADD_LIST}; do
    if ! prepare_new_osd "${disk}"; then
      log "ERROR- OSD fail to prepare. (${disk})"
    elif ! activate_osd ${disk}; then
      log "ERROR- OSD fail to activate. (${disk})"
    fi
  done
}

function calc_osd2add {
  if ! max_osd_num=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/max_osd); then
    max_osd_num=1
  fi

  if [ $(get_active_osd_nums) -ge "${max_osd_num}" ]; then
    echo "0"
  else
    local osd_num2add=$(expr "${max_osd_num}" - $(get_active_osd_nums))
    echo "${osd_num2add}"
  fi
}

function select_n_disks {
  # $1=disk_list $2=numbers to select. Use global variable $OSD_ADD_LIST
  local counter=0
  for disk in $1; do
    if [ "${counter}" -lt "$2" ]; then
      OSD_ADD_LIST="${OSD_ADD_LIST} ${disk}"
      let counter=counter+1
    fi
  done
}

function prepare_new_osd {
  if [ -z "$1" ]; then
    log "ERROR- Function prepare_new_osd need to assign a disk."
    return 1
  else
    local osd2prep="$1"
  fi

  if ! remove_lvs "${osd2prep}" &>/dev/null; then
    log "ERROR- Failed to remove lvm. (${osd2prep})"
    return 2
  fi

  if ! remove_raid "${osd2prep}" &>/dev/null; then
    log "ERROR- Failed to remvoe raid. (${osd2prep})"
    return 3
  fi

  if ! ceph-disk zap "${osd2prep}" &>/dev/null; then
    log "ERROR- Failed to zap disk. (${osd2prep})"
    return 4
  fi

  local CONT_NAME="$(create_cont_name "${osd2prep}")_prepare_$(date +%N)"
  if ! "$DOCKER_CMD" run -l CLUSTER="${CLUSTER}" -l CEPH=osd_prepare -l DEV_NAME="${osd2prep}" --name="${CONT_NAME}" \
    --privileged=true -v /dev/:/dev/ -e CDX_ENV="${CDX_ENV}" -e OSD_DEVICE="${osd2prep}" \
    "${DAEMON_VERSION}" osd_ceph_disk_prepare &>/dev/null; then
    return 5
  fi
}

function create_cont_name {
  # usage: create_cont_name DEV_PATH OSD_ID, e.g. create_cont_name /dev/sda 12 => OSD_12_sda
  if [ $# -ne 2 ] && [ $# -ne 1 ]; then
    log "ERROR- create_cont_name DEV_PATH OSD_ID"
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

function is_osd_running {
  # give a disk and check OSD container
  if [ -z "$1" ]; then
    log "ERROR- function is_osd_running need to assign an OSD."
    exit 1
  else
    local DEV_NAME="$1"
  fi

  # check running & exited containers
  local CONT_ID=$("${DOCKER_CMD}" ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME="${DEV_NAME}")
  if [ -z "${CONT_ID}" ]; then
    return 1
  fi
}

function is_osd_disk {
  # Check label partition table includes "ceph journal" or not
  if ! sgdisk --verify "$1" &>/dev/null; then
    return 1
  elif parted -s "$1" print 2>/dev/null | egrep -sq '^ 1.*ceph data' ; then
    return 0
  else
    return 1
  fi
}

# Find disks not only unmounted but also non-ceph disks
function get_avail_disks {
  local AVAL_D=$(get_disks | jq --raw-output .avalDisk)
  for disk in ${AVAL_D}; do
    echo "/dev/${disk}"
  done
}

function is_disk_ssd {
  # Detemine by the value 0:SSD 1:HDD
  if [ -z "$1" ]; then
    log "ERROR- function is_disk_ssd need to assign a DISK."
    exit 1
  else
    local DISK=$(echo "$1" | sed 's/\/dev\///g')
    local DISK_VALUE=$(cat /sys/block/${DISK}/queue/rotational 2>/dev/null || true)
  fi
  if [ "${DISK_VALUE}" == "0" ]; then
    return 0
  else
    return 1
  fi
}

function get_disks {
  local BLOCKS=$(readlink /sys/class/block/* -e | grep -v "usb" | grep -o "sd[a-z]$")
  [[ -n "${BLOCKS}" ]] || ( echo "" ; return 1 )
  local USB_D=$(readlink /sys/class/block/* -e | grep "usb" | grep -o "[sv]d[a-z]$" || true)
  local RSVD_D=""
  local SYS_D=""
  local AVAL_D=""
  if [[ "${RESERVED_SLOT}" == *","* ]]; then
    RESERVED_SLOT=${RESERVED_SLOT//,/ }
  fi
  for slot in ${RESERVED_SLOT}; do
    local RESERVED_D="${RESERVED_D} $(docker exec toolbox port-mapping.sh -s ${slot} 2>/dev/null || true)"
  done
  for disk in ${BLOCKS}; do
    if echo "${RESERVED_D}" | grep -q "${disk}"; then
      RSVD_D="${RSVD_D} ${disk}"
    elif [ -z "$(lsblk /dev/"${disk}" -no MOUNTPOINT)" ]; then
      AVAL_D="${AVAL_D} ${disk}"
    else
      SYS_D="${SYS_D} ${disk}"
    fi
  done
  # Remove space in the begining

  RSVD_D=$(echo ${RSVD_D} | sed 's/" /"/')
  AVAL_D=$(echo ${AVAL_D} | sed 's/" /"/')
  SYS_D=$(echo ${SYS_D} | sed 's/" /"/')
  local J_FORM="{\"systemDisk\":\"${SYS_D}\",\"usbDisk\":\"${USB_D}\",\"rsvdDisk\":\"${RSVD_D}\",\"avalDisk\":\"${AVAL_D}\"}"
  echo ${J_FORM}
}

function hotplug_OSD {
  inotifywait -r -m /dev/ -e CREATE -e DELETE | while read dev_msg; do
    local hotplug_disk=$(echo "$dev_msg" | awk '{print $1$3}')
    local action=$(echo "$dev_msg" | awk '{print $2}')

    if [[ "${hotplug_disk}" =~ /dev/sd[a-z]$ ]]; then
      case "${action}" in
        CREATE)
          run_osds
          ;;
        DELETE)
          log "Disk ${hotplug_disk} removed."
          if is_osd_running "${hotplug_disk}"; then
            local CONT_ID=$("${DOCKER_CMD}" ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME="${hotplug_disk}")
            "${DOCKER_CMD}" stop "${CONT_ID}" &>/dev/null || true
          fi
          ;;
        *)
          ;;
      esac
    fi
  done
}

function remove_lvs {
  if [ -z "$1" ]; then
    return 0
  else
    local disk="${1}"
  fi

  if ! local pv_display=$(pvdisplay -C --noheadings --separator ' | ' | grep "${disk}"); then
    return 0
  fi
  local pv_list=$(echo "${pv_display}" | awk -F "|" '{print $1}')
  local vg_list=$(echo "${pv_display}" | awk -F "|" '{print $2}')

  for vg in ${vg_list}; do
    local lv_list=$(lvdisplay -C --noheadings --separator ' | ' | grep -w "${vg}" | awk -F "|" '{print $1}')
    # if lvm mounted, donothing.
    for lv in ${lv_list}; do
      df | grep -q /dev/${vg}/${lv} && return 1
    done
    vgremove -f "${vg}" &>/dev/null
  done

  for pv in ${pv_list}; do
    pvremove -f "${pv}" &>/dev/null
  done
}

function remove_raid {
  if [ -z "$1" ]; then
    return 0
  else
    local disk=$(echo ${1} | sed 's/\/dev\///')
  fi
  local md_list=$(cat /proc/mdstat | grep md | grep ${disk} | awk '{print $1}')
  for md in ${md_list}; do
    local dev=$(cat /proc/mdstat | grep -w ${md} | awk '{print $5}' | sed 's/\[.*]//')
    mdadm --stop /dev/"${md}" &>/dev/null
    mdadm --zero-superblock /dev/${dev} &>/dev/null
  done
}
