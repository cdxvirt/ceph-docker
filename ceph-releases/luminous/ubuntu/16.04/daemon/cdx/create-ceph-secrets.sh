#!/bin/bash
set -e

#######
# ENV #
#######

: ${CEPH_NAMESPACE:="ceph"}
: ${POD_LABLE:="ceph-mon"}
: ${SECRET_NAMESPACE:="default"}
: ${SECRET_TYPE:="none"}
: ${CEPH_USER:="client.admin"}
: ${RBD_KEY_NAME:="ceph-secret"}
: ${CEPH_DASH_KEY_NAME:="dashboard-secrets"}
: ${CEPH_MON_DOMAIN_NAME:="false"}
: ${CEPH_EP_NAME:=ceph-mon.${CEPH_NAMESPACE}}

#########
# USAGE #
#########

function show_usage {
  echo "Usage: -n [ceph_namespace] -l [ceph-mon-label] -s [secret_namespace] -t [secret_type]"
  echo "       -d debug_mode       -h help             -D use_ceph_mon_domain_name"
  echo "secret type = [ rbd | ceph-dash ]"
  echo ""
  echo "ceph_namespace   [default: ${CEPH_NAMESPACE}]"
  echo "ceph-mon-label   [default: ${POD_LABLE}]"
  echo "secret_namespace [default: ${SECRET_NAMESPACE}]"
  echo "secret_type      [default: ${SECRET_TYPE}]"
}


###############
# GET OPTIONS #
###############

while getopts "n:l:s:t:hdD" OPTION; do
  case "${OPTION}" in
    n) CEPH_NAMESPACE="${OPTARG}" ;;
    l) POD_LABLE="${OPTARG}" ;;
    s) SECRET_NAMESPACE="${OPTARG}" ;;
    t) SECRET_TYPE="${OPTARG}" ;;
    h) show_usage; exit 0 ;;
    d) set -x ;;
    D) CEPH_MON_DOMAIN_NAME="true" ;;
  esac
done

function show_env {
  echo "ceph namespace: ${CEPH_NAMESPACE}"
  echo "ceph mon label: ${POD_LABLE}"
  echo "secret namespace: ${SECRET_NAMESPACE}"
  echo "secret type: ${SECRET_TYPE}"
  echo ""
}


###########
# RBD KEY #
###########

function create_rbd_key {
  show_env
  if "${KUBECTL}" get secret "${RBD_KEY_NAME}" --namespace="${SECRET_NAMESPACE}" &>/dev/null; then
    "${KUBECTL}" delete secret "${RBD_KEY_NAME}" --namespace="${SECRET_NAMESPACE}"
  fi
  KEY=$("${KUBECTL}" exec --namespace="${CEPH_NAMESPACE}" "${POD}" ceph auth print-key ${CEPH_USER} 2>/dev/null)
  "${KUBECTL}" create secret generic "${RBD_KEY_NAME}" --type=kubernetes.io/rbd --namespace="${SECRET_NAMESPACE}" \
  --from-literal=key="${KEY}"
}


##################
# CEPH DASHBOARD #
##################

function create_ceph_dash_key {
  show_env
  if "${KUBECTL}" get secret ${CEPH_DASH_KEY_NAME} --namespace="${CEPH_NAMESPACE}" &>/dev/null; then
    "${KUBECTL}" delete secret ${CEPH_DASH_KEY_NAME} --namespace="${CEPH_NAMESPACE}"
  fi
  "${KUBECTL}" exec --namespace="${CEPH_NAMESPACE}" "${POD}" ceph auth get ${CEPH_USER} 2>/dev/null > keyring
  if [ "${CEPH_MON_DOMAIN_NAME}" == "true" ]; then
    echo -e "[global]\nmon host = ${CEPH_EP_NAME}" > ceph.conf
  else
    "${KUBECTL}" exec --namespace="${CEPH_NAMESPACE}" "${POD}" cat /etc/ceph/ceph.conf > ceph.conf
  fi
  "${KUBECTL}" create secret generic ${CEPH_DASH_KEY_NAME} --namespace="${CEPH_NAMESPACE}" --from-file=keyring --from-file=ceph.conf
  rm keyring ceph.conf
}


########
# MAIN #
########

if ! KUBECTL=$(command -v kubectl); then
  echo "Command not found: kubectl"
  exit 2
fi

POD=$("${KUBECTL}" --namespace="${CEPH_NAMESPACE}" get pod -l name="${POD_LABLE}" 2>/dev/null | awk 'NR==2{print$1}')
if [ -z "${POD}" ]; then
  echo "Pod name with ${POD_LABLE} label & ${CEPH_NAMESPACE} namespace not found."
  exit 0
fi

case "${SECRET_TYPE}" in
  rbd)
    create_rbd_key;;
  ceph-dash)
    create_ceph_dash_key;;
  *)
    show_usage; exit 1;;
esac
