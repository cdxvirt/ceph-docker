#!/bin/bash

function cdx_controller {
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mkdir "${CLUSTER_PATH}" &>/dev/null || true
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mkdir "${CLUSTER_PATH}"/mon_host &>/dev/null || true
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "${CLUSTER_PATH}"/max_mon "${MAX_MON}" &>/dev/null || true

  while [ true ]; do
    controller_main
    sleep 30
  done
}

function controller_main {
  # get $MAX_MON & check it matching positive number
  if MAX_MON=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/max_mon); then
    if ! positive_num "${MAX_MON}"; then
      log "ERROR- MAX_MON should be positive number. (${MAX_MON})"
      return 0
    fi
  else
    log "ERROR- Can't read MAX_MON from etcd."
  fi

  get_mon_nodes

  # how many mons needs to add?
  current_mons=$(echo "${nodes_have_mon_label}" | wc -w)
  if [ "${current_mons}" -lt "${MAX_MON}" ]; then
    local mon_num2add=$(expr "${MAX_MON}" - "${current_mons}")
  else
    local mon_num2add=0
  fi

  # create kubernetes mon label
  local counter=0
  for mon2add in ${nodes_no_mon_label}; do
    if [ "${counter}" -lt "${mon_num2add}" ]; then
      kubectl "${K8S_CERT[@]}" label node "${mon2add}" \
        "${MON_LABEL}"=true --overwrite &>/dev/null && log "Add Mon node ${mon2add}"
      let counter=counter+1
    fi
  done

  # update endpoints
  if kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get ep "${K8S_EP_NAME}" &>/dev/null; then
    update_ceph_mon_ep
  else
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/global/mon_host "${CEPH_DOMAIN_NAME}" &>/dev/null || true
  fi
}

function get_mon_nodes {
  nodes_have_mon_label=$(kubectl "${K8S_CERT[@]}" get node --show-labels \
    |  grep -w "${MON_LABEL}" | awk '/ Ready/ { print $1 }')
  nodes_no_mon_label=$(kubectl "${K8S_CERT[@]}" get node --show-labels \
    |  grep -wv "${MON_LABEL}" | awk '/ Ready/ { print $1 }')
  etcd_mon_host=$(etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" ls ${CLUSTER_PATH}/mon_host | sed "s#.*/mon_host/##")
}

function update_ceph_mon_ep {
  local ep_list=""
  for mon_name in ${etcd_mon_host}; do
    local mon_ip=$(mon_name_2_mon_ip "${mon_name}")
    # when monitor not ready, skip it.
    if ! check_mon_connection "${mon_ip}"; then
      continue
    elif [ -z "${ep_list}" ]; then
      local mon_ip_ep_format="{\"ip\": \"${mon_ip}\"}"
      ep_list="${mon_ip_ep_format}"
    # more than one item, josn form needs ",",
    else
      local mon_ip_ep_format="{\"ip\": \"${mon_ip}\"}"
      ep_list="${ep_list}, ${mon_ip_ep_format}"
    fi
  done

  # make sure ep_list is not null
  if [ -n "${ep_list}" ]; then
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "${CLUSTER_PATH}"/global/mon_host "${CEPH_DOMAIN_NAME}" &>/dev/null || true
    local UPDATE_EP="kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" \
      patch ep "${K8S_EP_NAME}" -p \
      '{\"subsets\": [{\"addresses\": [${ep_list}],\"ports\": [{\"port\": 6789,\"protocol\": \"TCP\"}]}]}'"
    eval "${UPDATE_EP}" >/dev/null
  else
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "${CLUSTER_PATH}"/global/mon_host &>/dev/null || true
  fi
}

function check_mon_connection {
  if curl -d "null" "$1":6789 &>/dev/null; then
    return 0
  else
    return 1
  fi
}

function node_ip_2_pod_name {
  if [ -z "$1" ]; then
    log "ERROR- node_ip_2_pod_name kubernetes_IP"
    exit 1
  fi
  kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get pod -o wide --selector name="${MON_POD_SELECTOR}" | grep -w "$1" | awk '{ print $1 }'
}

function node_ip_2_hostname {
  if [ -z "$1" ]; then
    log "ERROR- node_ip_2_hostname kubernetes_IP"
    exit 1
  fi
  local pod_name=$(node_ip_2_pod_name "$1")
  kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" exec "${pod_name}" hostname 2>/dev/null
}

function mon_name_2_mon_ip {
  if [ -z "$1" ]; then
    log "ERROR- mon_name_2_mon_ip mon_name"
    exit 1
  fi
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/mon_host/"$1" 2>/dev/null | sed 's/:6789//'
}
