#!/bin/bash
set -e

function exec_own_command {
  if [ -z $1 ]; then
    exec bash
  else
    exec $@
  fi
}

function is_cdx_env {
  if [ -z ${CDX_ENV} ]; then
    return 1
  elif [ ${CDX_ENV} == "true" ]; then
    return 0
  else
    return 1
  fi
}

## MAIN
echo "NOW IN CDX/CDX"
if is_cdx_env; then
  source cdx/cdx-env.sh
fi
