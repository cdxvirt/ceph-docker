#!/bin/bash

# Need $BENCH_OSD_TYPE $OSD_NUM $STAMP $REPLICA $PG_NUM

function create_bench_crush {
  # Create rules
  ceph "${CLI_OPTS[@]}" osd crush add-bucket CEPH-AUTO-BENCH root
  ceph "${CLI_OPTS[@]}" osd crush rule create-simple ceph_auto_bench CEPH-AUTO-BENCH host firstn
  # Get crush tree
  CRUSH_TREE_JSON=$(ceph "${CLI_OPTS[@]}" osd crush tree -f json)
  # Link to CEPH-AUTO-BENCH
  NODE=$(eval "echo \${CRUSH_TREE_JSON} | jq --raw-output '.[] | select(.name==\"${BENCH_OSD_TYPE}\") | .items[].name'")
  for node in ${NODE}; do
    ceph "${CLI_OPTS[@]}" osd crush link ${node} root=CEPH-AUTO-BENCH
  done
  # Adjust OSD number
  for node in ${NODE}; do
    local OSD=""
    OSD=$(eval "echo \${CRUSH_TREE_JSON} | jq --raw-output '.[] | select(.name==\"${BENCH_OSD_TYPE}\")|  .items[] | select(.name==\"${node}\") | .items[].name'")
    OSD=($OSD)
    if [ "${OSD_NUM}" == "all" ]; then
      return 0
    else
      local RM_OSD=$(expr "${#OSD[@]}" - "${OSD_NUM}")
      local RM_OSD_ID=""
    fi
    until [ "${RM_OSD}" -le 0 ]; do
      RM_OSD_ID=$(expr "${#OSD[@]}" - "${RM_OSD}")
      ceph "${CLI_OPTS[@]}" osd crush rm "${OSD[${RM_OSD_ID}]}"
      ((RM_OSD--))
    done
  done
}

function backup_crushmap {
  # Backup crushmap
  ceph "${CLI_OPTS[@]}" osd getcrushmap -o crushmap
  #  Put on etcd
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mkdir "${CLUSTER_PATH}"/crushMap &>/dev/null || true
  uuencode crushmap - | etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "${CLUSTER_PATH}"/crushMap/"${STAMP}"
}

function recovery_crushmap {
  # Recovery crushmap
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get "${CLUSTER_PATH}"/crushMap/"${STAMP}" | uudecode -o crushmap
  ceph "${CLI_OPTS[@]}" osd setcrushmap -i crushmap
}

function create_bench_pool {
  # Create bench pool
  ceph "${CLI_OPTS[@]}" osd pool rm ceph-auto-bench ceph-auto-bench --yes-i-really-really-mean-it
  ceph "${CLI_OPTS[@]}" osd pool create ceph-auto-bench "${PG_NUM}" "${PG_NUM}" replicated ceph_auto_bench
  ceph "${CLI_OPTS[@]}" osd pool set ceph-auto-bench size "${REPLICA}"
}

function remove_bench_pool {
  # Remove bench pool
  ceph "${CLI_OPTS[@]}" osd pool rm ceph-auto-bench ceph-auto-bench --yes-i-really-really-mean-it
}
