#!/bin/bash
set -e

DISKS_STATUS_DIR="/disks-status"

function get_avail_disks {
  BLOCKS=$(readlink /sys/class/block/* -e | grep -v "usb" | grep -o "sd[a-z]$")
  : ${OSD_PATH_BASE:="/var/lib/ceph/osd/ceph"}
  [[ -n "${BLOCKS}" ]] || ( echo "" ; return 1 )

  while read disk ; do
    # Double check it
    if ! lsblk /dev/${disk} > /dev/null 2>&1; then
      continue
    fi

    if [ -z "$(lsblk /dev/${disk} -no MOUNTPOINT)" ]; then
      # Found it
      echo "${disk}"
    elif lsblk /dev/${disk} | grep -q "${OSD_PATH_BASE}"; then
      echo "${disk}"
    fi
  done < <(echo "$BLOCKS")
}

function is_osd_disk {
  # Check label partition table includes "ceph journal" or not
  if ! sgdisk --verify $1 &>/dev/null; then
    return 1
  elif parted --script $1 print 2>/dev/null | grep -qE '^ 1.*ceph data' ; then
    return 0
  else
    return 1
  fi
}

function check_osd_disk {
  local target_disk="$1"
  local data_part="${target_disk}1"
  if grep -q "${data_part}" /proc/mounts; then
    OSD_ID=$(grep "${data_part}" /proc/mounts | awk '{print $2}' | sed -r 's/^.*-([0-9]+)$/\1/')
    return 0
  elif ceph-disk --setuser ceph --setgroup disk activate ${data_part} --no-start-daemon &>/dev/null; then
    OSD_ID=$(grep "${data_part}" /proc/mounts | awk '{print $2}' | sed -r 's/^.*-([0-9]+)$/\1/')
    return 0
  else
    umount ${data_part} &>/dev/null || true
    return 1
  fi
}


function cdx_disks_status {
  local CURRENT_DISKS=$(get_avail_disks)
  local OLD_DISK_INFO=$(ls ${DISKS_STATUS_DIR})

  # sync disks item
  for disk in ${OLD_DISK_INFO}; do
    echo ${CURRENT_DISKS} | grep -q ${disk} || rm ${DISKS_STATUS_DIR}/${disk}
  done

  for disk in ${CURRENT_DISKS}; do
    touch ${DISKS_STATUS_DIR}/${disk}
    local disk_path="/dev/${disk}"
    if ! is_osd_disk ${disk_path}; then
      echo "not-osd" > ${DISKS_STATUS_DIR}/${disk}
    elif check_osd_disk ${disk_path}; then
      echo "osd.${OSD_ID}" > ${DISKS_STATUS_DIR}/${disk}
      unset OSD_ID
    else
      echo "unknown-osd" > ${DISKS_STATUS_DIR}/${disk}
    fi
  done
}

function cdx_prepare_disk {
  local all_disks=$(ls ${DISKS_STATUS_DIR})
  local max_osd_num=$1
  local current_osd_num=$(grep "osd." ${DISKS_STATUS_DIR}/* 2>/dev/null | wc -w)
  local prepare_osd_list=""
  local osd_num2add=$(expr ${max_osd_num} - ${current_osd_num})
  local counter=0

  if [ "${osd_num2add}" -lt "1" ]; then
    return 0
  fi

  for disk in ${all_disks}; do
    if [ "${counter}" -ge "${osd_num2add}" ]; then
      break
    elif grep -q "not-osd" ${DISKS_STATUS_DIR}/${disk}; then
      prepare_osd_list="${prepare_osd_list} ${disk}"
      let counter=counter+1
    fi
  done

  if [[ ${OSD_BLUESTORE} -eq 1 ]]; then
    for disk in ${prepare_osd_list}; do
      ceph-disk -v zap /dev/${disk}
      ceph-disk -v prepare --bluestore /dev/${disk}
    done
  else
    for disk in ${prepare_osd_list}; do
      ceph-disk -v zap /dev/${disk}
      ceph-disk -v prepare --filestore /dev/${disk}
    done
  fi
}

function cdx_run_osd {
  local osd_list=$(grep "osd." ${DISKS_STATUS_DIR}/* 2>/dev/null | sed -r 's/^.*.([0-9]+)$/\1/')
  for osd in ${osd_list}; do
    if ! ps -ef | grep -q "[c]eph-osd -i ${osd}"; then
      ceph-osd -i ${osd}
    fi
  done
}

## MAIN
echo "NOW IN CDX/OSD"
if is_cdx_env; then
  get_config
  check_config
  get_admin_key
  check_admin_key
  mkdir -p ${DISKS_STATUS_DIR}
  while true; do
    cdx_disks_status
    cdx_prepare_disk ${MAX_OSD}
    sleep 2
  done &
  while true; do
    cdx_run_osd
    sleep 10
  done
fi
