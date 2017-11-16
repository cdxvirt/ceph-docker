#!/bin/bash

source cdx/crush.sh
source cdx/osd-api.sh

function check_osd_env {
  check_docker_cmd

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
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "${CLUSTER_PATH}"/max_osd "${MAX_OSD}" &>/dev/null || true
  ceph "${CLI_OPTS[@]}" osd crush add-bucket "${HOSTNAME}" host &>/dev/null
  # XXX: need more flexiable
  ceph "${CLI_OPTS[@]}" osd crush move "${HOSTNAME}" root=default &>/dev/null
}

function check_docker_cmd {
  if ! DOCKER_CMD=$(which docker); then
    log "ERROR- docker: command not found."
    exit 1
  elif ! "${DOCKER_CMD}" -v | grep -wq "version"; then
    "$DOCKER_CMD" -v
    exit 1
  fi
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
  check_osd_env
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
    log "ERROR- No available disk"
    return 0
  fi

  for disk in ${DISK_LIST}; do
    if is_osd_disk "${disk}"; then
      activate_osd "${disk}" || true
    fi
  done
}

function activate_osd {
  if [ -z "$1" ]; then
    log "ERROR- Function activate_osd need to assign a OSD."
    return 1
  else
    local disk2act="$1"
  fi

  # if OSD is running or come from another cluster, then return 0.
  if is_osd_running "${disk2act}"; then
    local CONT_ID=$("${DOCKER_CMD}" ps -q -f LABEL=CEPH=osd -f LABEL=DEV_NAME=${disk2act})
    log "${disk2act} is running as OSD (${CONT_ID})."
    return 0
  elif ! is_osd_correct ${disk2act}; then
    log "WARN- The OSD disk ${disk2act} unable to activate for current Ceph cluster."
    return 2
  fi

  local CONT_NAME=$(create_cont_name "${disk2act}" "${OSD_ID}")
  if "$DOCKER_CMD" inspect "${CONT_NAME}" &>/dev/null; then
    "$DOCKER_CMD" rm "${CONT_NAME}" >/dev/null
  fi

  # XXX: auto find DAEMON_VERSION
  "$DOCKER_CMD" run -d -l CLUSTER="${CLUSTER}" -l CEPH=osd -l DEV_NAME="${disk2act}" -l OSD_ID="${OSD_ID}" \
    --name="${CONT_NAME}" --privileged=true --net=host --pid=host -v /dev:/dev "${OSD_MEM[@]}" "${OSD_CPU_CORE[@]}" \
    -e CDX_ENV="${CDX_ENV}" -e DEBUG="${DEBUG}" -e OSD_DEVICE="${disk2act}" \
    "${DAEMON_VERSION}" osd_ceph_disk_activate >/dev/null

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

  if [ -n "${OSD_ADD_LIST}" ]; then
    # clear lvm & raid
    clear_lvs_disks
    clear_raid_disks
  else
    return 0
  fi

  for disk in ${OSD_ADD_LIST}; do
    if ! prepare_new_osd "${disk}"; then
      log "ERROR- OSD ${disk} fail to prepare."
    elif ! activate_osd ${disk}; then
      log "ERROR- OSD ${disk} fail to activate."
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

  if ! ceph-disk zap "${osd2prep}" &>/dev/null; then
    log "ERROR- Failed to zap disk"
    return 1
  fi

  local CONT_NAME="$(create_cont_name "${osd2prep}")_prepare_$(date +%N)"
  if ! "$DOCKER_CMD" run -l CLUSTER="${CLUSTER}" -l CEPH=osd_prepare -l DEV_NAME="${osd2prep}" --name="${CONT_NAME}" \
    --privileged=true -v /dev/:/dev/ -e CDX_ENV="${CDX_ENV}" -e OSD_DEVICE="${osd2prep}" \
    "${DAEMON_VERSION}" osd_ceph_disk_prepare &>/dev/null; then
    return 2
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
    log "ERROR- function is_osd_running need to assign a OSD."
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

function is_osd_correct {
  if [ -z "$1" ]; then
    log "ERROR- function is_osd_correct need to assign a OSD."
    exit 1
  else
    # FIXME: disk2verify is a variable ti find ceph data JOURNAL partition.
    disk2verify="$1"
  fi
  disk2verify="${disk2verify}1"

  # check OSD mountable
  if ! ceph-disk --setuser ceph --setgroup disk activate "${disk2verify}" --no-start-daemon &>/dev/null; then
    OSD_ID=""
    umount "${disk2verify}" &>/dev/null || true
    return 2
  fi

  # check OSD Key
  local OSD_PATH=$(df | grep "${disk2verify}" | awk '{print $6}')
  local TMP_OSD_ID=$(echo "${OSD_PATH}" | sed "s/.*${CLUSTER}-//g")
  local OSD_KEY_IN_CEPH=$(ceph "${CLI_OPTS[@]}" auth get-key osd."${TMP_OSD_ID}" 2>/dev/null)
  if [ -z "${OSD_KEY_IN_CEPH}" ]; then
    return 3
  elif cat "${OSD_PATH}"/keyring | grep -q "${OSD_KEY_IN_CEPH}"; then
    OSD_ID="${TMP_OSD_ID}"
    umount "${disk2verify}"
    return 0
  else
    return 4
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

function get_disks {
  local BLOCKS=$(readlink /sys/class/block/* -e | grep -v "usb" | grep -o "sd[a-z]$")
  [[ -n "${BLOCKS}" ]] || ( echo "" ; return 1 )
  local SYS_D=""
  local USB_D=$(readlink /sys/class/block/* -e | grep "usb" | grep -o "[sv]d[a-z]$" || true)
  local AVAL_D=""
  for disk in ${BLOCKS}; do
    if [ -z "$(lsblk /dev/"${disk}" -no MOUNTPOINT)" ]; then
      AVAL_D="${AVAL_D} ${disk}"
    else
      SYS_D="${SYS_D} ${disk}"
    fi
  done
  # Remove space in the begining
  AVAL_D=$(echo ${AVAL_D} | sed 's/" /"/')
  SYS_D=$(echo ${SYS_D} | sed 's/" /"/')
  local J_FORM="{\"systemDisk\":\"${SYS_D}\",\"usbDisk\":\"${USB_D}\",\"avalDisk\":\"${AVAL_D}\"}"
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

# XXX: We suppose we don't need any lvs and raid disks at all and just delete them
function clear_lvs_disks {
  lvs=$(lvscan | grep '/dev.*' | awk '{print $2}')

  if [ -n "$lvs" ]; then
    log "Find logic volumes, inactive them."
    for lv in $lvs
    do
      lvremove -f "${lv//\'/}"
    done

  fi
  vgs=$(vgdisplay -C --noheadings --separator '|' | cut -d '|' -f 1)
  if [ -n "$vgs" ]; then
    log "Find VGs, delete them."
    for vg in $vgs
    do
      vgremove -f "$vg"
    done

  fi
  pvs=$(pvscan -s | grep '/dev/sd[a-z].*' || true)
  if [ -n "$pvs" ]; then
    log "Find PVs, delete them."
    for pv in $pvs
    do
      pvremove -ff -y "$pv"
    done

  fi
}

function clear_raid_disks {
  mds=$(mdadm --detail --scan  | awk '{print $2}')
  if [ -z "${mds}" ]; then
    # Nothing to do
    return 0
  fi
  for md in ${mds}
  do
    devs=$(mdadm --detail --export "${md}" | grep MD_DEVICE_.*_DEV | cut -d '=' -f 2)
    if [ -z "$devs" ]; then
      log "No invalid devices"
      return 1
    fi
    mdadm --stop "${md}"
    for dev in ${devs}
    do
      log "Clear MD device: $dev"
      mdadm --wait --zero-superblock --force "$dev"
    done
  done
}
