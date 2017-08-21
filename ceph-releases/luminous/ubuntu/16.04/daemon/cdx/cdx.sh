#!/bin/bash
set -e

function cdx_entrypoint {
  CDX_CMD=$(echo ${1} | sed 's/cdx_//')
  case "${CDX_CMD}" in
    mon)
      source cdx/mon.sh
      source start_mon.sh
      cdx_mon
      start_mon
      ;;
    osd)
      source cdx/osd.sh
      cdx_osd
      ;;
    controller)
      source cdx/controller.sh
      cdx_controller
      ;;
    ceph-api)
      source cdx/api.sh
      shift
      cdx_ceph_api $@
      ;;
    admin)
      get_ceph_admin
      shift
      exec $@
      ;;
    verify)
      source cdx/verify.sh
      cdx_verify
      ;;
  esac
}

function is_cdx_env {
  if [ -z "${CDX_ENV}" ]; then
    return 1
  elif [ "${CDX_ENV}" == "true" ]; then
    return 0
  else
    return 1
  fi
}

function positive_num {
  local re="^[1-9][0-9]*$"
  if [[ "$1" =~ $re ]]; then
    return 0
  else
    return 1
  fi
}

function natural_num {
  local re="^[0-9]+([.][0-9]+)?$"
  if [[ "$1" =~ $re ]]; then
    return 0
  else
    return 1
  fi
}

function get_ceph_admin {
  # if ceph.conf not exist then get it.
  if [ ! -e /etc/ceph/"${CLUSTER}".conf ] || [ "$1" == "force" ]; then
    get_config
    check_config
    get_admin_key
    check_admin_key
  fi
}

## MAIN
if is_cdx_env; then
  source cdx/cdx-env.sh
fi
