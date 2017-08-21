#!/bin/bash
set -e

function vlog_green {
  echo -e "\033[1;32m[SUCCESS]\033[0m $*"
}

function vlog_red {
  echo -e "\033[1;31m[FAILED]\033[0m $*"
}

function vlog_normal {
  echo -e "\n[INFO] $(date '+%F %T') $*"
}

function get_verify_options {
  VFY_LIST=""
  if echo "${CEPH_VFY}" | grep -qw "all"; then
    VFY_LIST="rbd rbd_clean rgw rgw_clean mds mds_clean"
    return 0
  fi

  if echo "${CEPH_VFY}" | grep -qw "rbd"; then
    VFY_LIST="${VFY_LIST} rbd rbd_clean"
  fi

  if echo "${CEPH_VFY}" | grep -qw "rgw"; then
    VFY_LIST="${VFY_LIST} rgw rgw_clean"
  fi

  if echo "${CEPH_VFY}" | grep -qw "mds"; then
    VFY_LIST="${VFY_LIST} mds mds_clean"
  fi
}

function prepare_test_file {
  # only rbd rgw mds needs test file
  if ! command -v md5sum &>/dev/null; then
    vlog_red "md5sum: command not found. We meed to verify checksum."
    exit 1
  elif [ -z "${VFY_LIST}" ]; then
    return 0
  fi
  vlog_normal "PREPARE TEST FILE"
  # create test file
  if [ -n "${HTTP_VFY_PATH}" ]; then
    vlog_normal "Test file is downloading."
    wget -q "${HTTP_VFY_PATH}" -O "${VFY_TEST_FILE}" || vlog_red "Failed to download file from ${HTTP_VFY_PATH}"
  else
    dd if=/dev/zero of="${VFY_TEST_FILE}" bs=1M count=50 &>/dev/null; sync
  fi
  # check test file size, 4.7G (5049942016) ~ 1M (1048576)
  local size_of_file=$(stat --printf="%s" "${VFY_TEST_FILE}")
  if [ "${size_of_file}" -gt "5049942016" ] || [ "${size_of_file}" -lt "1048576" ]; then
    vlog_red "Size of TEST_FILE is ${size_of_file} bytes, must under 4.7G & above 1M."
    exit 1
  fi

  md5sum "${VFY_TEST_FILE}" > "${VFY_TEST_FILE}".md5
  VFY_MD5=$(cat ${VFY_TEST_FILE}.md5 | awk '{print $1}')
  vlog_green "Checksum of test file: (${VFY_MD5})"
}

function vfy_cluster {
  local mon_status=$(ceph "${CLI_OPTS[@]}" quorum_status 2>/dev/null)
  local mon_ranks=$(echo "${mon_status}" | jq --raw-output ".monmap.mons[].rank")
  local ceph_status=$(ceph "${CLI_OPTS[@]}" status -f json 2>/dev/null)
  local osd_stat=$(ceph "${CLI_OPTS[@]}" osd stat -f json 2>/dev/null)
  vlog_normal "CLIENT VERSION"
  ceph "${CLI_OPTS[@]}" version 2>/dev/null
  vlog_normal "CLUSTER VERSION"
  ceph "${CLI_OPTS[@]}" tell mon.$(echo ${mon_status} | jq --raw-output ".quorum_leader_name") version 2>/dev/null
  vlog_normal "CEPH CLUSTER HEALTH"
  echo "${ceph_status}" | jq --raw-output ".health.overall_status"
  vlog_normal "MON STATUS"
  for rank in ${mon_ranks}; do
    eval "echo \${mon_status} | jq --raw-output '\"${rank}: \(.monmap.mons[${rank}].name) \(.monmap.mons[${rank}].addr)\"'"
  done
  vlog_normal "OSD STATUS"
  echo "${osd_stat}" | jq --raw-output '"\(.num_osds) osds \(.num_up_osds) up \(.num_in_osds) in"'
}

function vfy_rbd {
  vlog_normal "RBD VERIFY"
  # check rbd pool
  if ! rados "${CLI_OPTS[@]}" lspools | grep -wq "${RBD_VFY_POOL}"; then
    vlog_red "NO ${RBD_VFY_POOL} pool"
    return 0
  fi
  # if old rbd verify image exist, remove it first.
  if (rbd "${CLI_OPTS[@]}" -p "${RBD_VFY_POOL}" ls | grep -wq "${RBD_VFY_IMAGE}") && \
    (! timeout 30 rbd "${CLI_OPTS[@]}" -p "${RBD_VFY_POOL}" rm "${RBD_VFY_IMAGE}" &>/dev/null); then
    vlog_red "Failed to remove ${RBD_VFY_POOL}/${RBD_VFY_IMAGE}"
    return 0
  fi
  # check volume /dev
  if ! df | grep "/dev$" | grep -wq "devtmpfs"; then
    vlog_red "RBD needs /dev as a volume"
    return 0
  fi
  # check rbd mount path
  if df | grep -q "${RBD_MNT_PATH}$"; then
    RBD_MNT_CREATED=false
    vlog_red "RBD mount point ${RBD_MNT_PATH} already used."
    return 0
  elif [ -d "${RBD_MNT_PATH}" ]; then
    RBD_MNT_CREATED=false
  elif [ -e "${RBD_MNT_PATH}" ]; then
    vlog_red "RBD mount point ${RBD_MNT_PATH} is a file."
    return 0
  else
    RBD_MNT_CREATED=true
    mkdir -p "${RBD_MNT_PATH}"
  fi
  # create image, map & mount
  if ! timeout 10 rbd "${CLI_OPTS[@]}" -p "${RBD_VFY_POOL}" create "${RBD_VFY_IMAGE}" --size 5G &>/dev/null; then
    vlog_red "Failed to create RBD image ${RBD_VFY_IMAGE}"
    return 0
  elif ! RBD_DEV=$(timeout 10 rbd "${CLI_OPTS[@]}" -p "${RBD_VFY_POOL}" map "${RBD_VFY_IMAGE}" 2>/dev/null); then
    vlog_red "Failed to map RBD image ${RBD_VFY_IMAGE}"
    return 0
  elif ! mkfs.ext4 "${RBD_DEV}" &>/dev/null; then
    vlog_red "Failed to mkfs.ext4 on ${RBD_DEV}"
    return 0
  elif ! mount "${RBD_DEV}" "${RBD_MNT_PATH}" &>/dev/null; then
    vlog_red "Failed to mount ${RBD_DEV}"
    return 0
  fi
  # test RBD image & checksum
  if ! cp "${VFY_TEST_FILE}" "${RBD_MNT_PATH}"  &>/dev/null; then
    vlog_red "Failed to copy file into RBD image ${RBD_VFY_IMAGE}"
    return 0
  elif ! local VFY_INTO_RBD_MD5=$(md5sum "${RBD_MNT_PATH}"/"${VFY_TEST_FILE}" | awk '{print $1}') \
    || [ "${VFY_INTO_RBD_MD5}" != "${VFY_MD5}" ]; then
    vlog_red "Wrong checksum when copy into RBD image (${VFY_INTO_RBD_MD5})"
    return 0
  elif ! cp "${RBD_MNT_PATH}"/"${VFY_TEST_FILE}" TEST-FILE-FROM-RBD &>/dev/null; then
    vlog_red "Failed to copy file from RBD image ${RBD_VFY_IMAGE}"
    return 0
  elif ! local VFY_FROM_RBD_MD5=$(md5sum TEST-FILE-FROM-RBD | awk '{print $1}') \
    || [ "${VFY_FROM_RBD_MD5}" != "${VFY_MD5}" ]; then
    vlog_red "Wrong checksum when copy from RBD image (${VFY_FROM_RBD_MD5})"
    return 0
  else
    vlog_green "Checksum of RBD oprations is correct (${VFY_FROM_RBD_MD5})"
  fi
  # remove RBD IMAGE & DEVICE
  if ! umount "${RBD_DEV}" &>/dev/null; then
    vlog_red "Failed to unmount ${RBD_DEV}"
    return 0
  elif ! timeout 30 rbd "${CLI_OPTS[@]}" unmap "${RBD_DEV}" &>/dev/null; then
    vlog_red "Failed to unmap ${RBD_DEV}"
    return 0
  elif ! timeout 30 rbd "${CLI_OPTS[@]}" -p "${RBD_VFY_POOL}" rm "${RBD_VFY_IMAGE}" &>/dev/null; then
    vlog_red "Failed to remove ${RBD_VFY_POOL}/${RBD_VFY_IMAGE}"
    return 0
  else
    rm TEST-FILE-FROM-RBD
    vlog_green "RBD works well."
  fi
}

function vfy_rbd_clean {
  umount "${RBD_DEV}" &>/dev/null || true
  rbd "${CLI_OPTS[@]}" unmap "${RBD_DEV}" &>/dev/null || true
  rbd "${CLI_OPTS[@]}" -p "${RBD_VFY_POOL}" rm "${RBD_VFY_IMAGE}" &>/dev/null || true
  rm TEST-FILE-FROM-RBD &>/dev/null || true
  if [ "${RBD_MNT_CREATED}" == "true" ]; then
    rm -r "${RBD_MNT_PATH}" &>/dev/null || true
  fi
}

function vfy_rgw {
  vlog_normal "RGW VERIFY"
  # check s3cmd config sample
  if [ ! -e /cdx/s3cfg ]; then
    vlog_red "/cdx/s3cfg is missing."
    return 0
  else
    cp /cdx/s3cfg /root/.s3cfg
  fi
  # check rgw root pool & create account for verifing.
  if ! rados "${CLI_OPTS[@]}" lspools | grep -q ".rgw.root"; then
    vlog_red "RGW pool .rgw.root not found."
    return 0
  elif ! radosgw-admin "${CLI_OPTS[@]}" user create --uid="${RGW_VFY_UID}" --display-name="${RGW_VFY_UID}-fullname" \
    --access-key="${RGW_VFY_KEY}" --secret-key="${RGW_VFY_KEY}" &>/dev/null; then
    vlog_red "Failed to create rgw account uid:${RGW_VFY_UID} key:${RGW_VFY_KEY}"
    return 0
  fi
  # get RGW website IP & check connection
  if [ -z "${RGW_VFY_SITE}" ]; then
    RGW_VFY_SITE=$(kubectl "${K8S_CERT[@]}" "${K8S_NAMESPACE[@]}" get pod -o wide | awk '/ceph-rgw-/ {print $7}' | head -n 1)
  fi
  if [ -z "${RGW_VFY_SITE}" ]; then
    vlog_red "Please assign \$RGW_VFY_SITE"
    return 0
  elif ! curl -s "${RGW_VFY_SITE}":"${RGW_VFY_PORT}" | grep -q "ListAllMyBucketsResult"; then
    vlog_red "Failed to connect to ${RGW_VFY_SITE}:${RGW_VFY_PORT}"
    return 0
  fi
  # edit s3cfg, upload & download test file
  sed -i s/AWS_ACCESS_KEY_PLACEHOLDER/"${RGW_VFY_KEY}"/ /root/.s3cfg || true
  sed -i s/AWS_SECRET_KEY_PLACEHOLDER/"${RGW_VFY_KEY}"/ /root/.s3cfg || true
  sed -i "s/host_base = localhost/host_base = ${RGW_VFY_SITE}:${RGW_VFY_PORT}/" /root/.s3cfg || true
  sed -i "s/host_bucket = localhost/host_bucket = ${RGW_VFY_SITE}:${RGW_VFY_PORT}/" /root/.s3cfg || true
  if ! s3cmd ls &>/dev/null; then
    vlog_red "Failed to connect to ${RGW_VFY_SITE}:${RGW_VFY_PORT} with s3cmd"
    return 0
  elif ! s3cmd mb s3://"${RGW_VFY_BUCKET}" &>/dev/null; then
    vlog_red "Failed to make bucket s3://${RGW_VFY_BUCKET}"
    return 0
  elif ! s3cmd put "${VFY_TEST_FILE}" s3://"${RGW_VFY_BUCKET}" &>/dev/null; then
    vlog_red "Failed to upload file into s3://${RGW_VFY_BUCKET}"
    return 0
  elif ! s3cmd setacl s3://"${RGW_VFY_BUCKET}"/"${VFY_TEST_FILE}" --acl-public &>/dev/null; then
    vlog_red "Failed to set acl on s3://${RGW_VFY_BUCKET}"
    return 0
  elif ! wget -q "${RGW_VFY_SITE}":"${RGW_VFY_PORT}"/"${RGW_VFY_BUCKET}"/"${VFY_TEST_FILE}" -O TEST-FILE-FROM-RGW; then
    vlog_red "Failed to download file from ${RGW_VFY_SITE}:${RGW_VFY_PORT}"
    return 0
  elif ! local VFY_FROM_RGW_MD5=$(md5sum TEST-FILE-FROM-RGW | awk '{print $1}') \
    || [ "${VFY_FROM_RGW_MD5}" != "${VFY_MD5}" ]; then
    vlog_red "Wrong checksum when download from RGW website ${RGW_VFY_SITE}:${RGW_VFY_PORT} (${VFY_FROM_RGW_MD5})"
    return 0
  else
    vlog_green "Checksum of RGW oprations is correct (${VFY_FROM_RGW_MD5})"
  fi
  # remove file & account
  if ! s3cmd del s3://"${RGW_VFY_BUCKET}"/"${VFY_TEST_FILE}" &>/dev/null; then
    vlog_red "Falied to delete file on s3://${RGW_VFY_BUCKET}"
    return 0
  elif ! s3cmd rb s3://"${RGW_VFY_BUCKET}" --recursive &>/dev/null; then
    vlog_red "Falied to remove bucket on s3://${RGW_VFY_BUCKET}"
    return 0
  elif ! radosgw-admin "${CLI_OPTS[@]}" user rm --uid="${RGW_VFY_UID}" &>/dev/null; then
    vlog_red "Failed to remove rgw account uid:${RGW_VFY_UID}"
    return 0
  else
    vlog_green "RGW works well."
  fi
}

function vfy_rgw_clean {
  rm TEST-FILE-FROM-RGW &>/dev/null || true
  if timeout 10 s3cmd ls s3://"${RGW_VFY_BUCKET}" &>/dev/null; then
    s3cmd rb s3://"${RGW_VFY_BUCKET}" --recursive &>/dev/null || true
  fi
  radosgw-admin "${CLI_OPTS[@]}" user rm --uid="${RGW_VFY_UID}" &>/dev/null || true
}

function vfy_mds {
  vlog_normal "MDS VERIFY"
  local mds_status=$(ceph "${CLI_OPTS[@]}" mds stat -f json 2>/dev/null)
  local ceph_status=$(ceph "${CLI_OPTS[@]}" status -f json 2>/dev/null)
  local mds_health=$(echo ${ceph_status} | jq --raw-output .fsmap.by_rank[].status)
  local admin_key=$(ceph "${CLI_OPTS[@]}" auth print-key client.admin 2>/dev/null)
  local mon_ip=$(echo ${ceph_status} | jq --raw-output ".monmap.mons[0].addr" | sed "s#/0##")
  # find cephfs filesystem
  if ! echo "${mds_status}" | jq --raw-output ".fsmap.filesystems[].mdsmap.fs_name" | grep -q "${CEPHFS_VFY_FS}"; then
    vlog_red "Ceph filesystem ${CEPHFS_VFY_FS} not found."
    return 0
  elif ! echo "${mds_health}" | grep -q "up:active$"; then
    vlog_red "Ceph MDS failed, ${mds_health}"
    return 0
  fi
  # check cephfs mount path
  if df | grep -q "${CEPHFS_MNT_PATH}$"; then
    CEPHFS_MNT_CREATED=false
    vlog_red "CEPHFS mount point ${CEPHFS_MNT_PATH} already used."
    return 0
  elif [ -d "${CEPHFS_MNT_PATH}" ]; then
    CEPHFS_MNT_CREATED=false
  elif [ -e "${CEPHFS_MNT_PATH}" ]; then
    vlog_red "CEPHFS mount point ${CEPHFS_MNT_PATH} is a file."
    return 0
  else
    CEPHFS_MNT_CREATED=true
    mkdir -p "${CEPHFS_MNT_PATH}"
  fi
  # mount, copy verify
  if ! timeout 30 mount.ceph "${mon_ip}":/ "${CEPHFS_MNT_PATH}" -o name=admin,secret="${admin_key}"; then
    vlog_red "Failed to mount Ceph filesystem ${CEPHFS_VFY_FS}"
    return 0
  elif ! cp "${VFY_TEST_FILE}" "${CEPHFS_MNT_PATH}" &>/dev/null; then
    vlog_red "Failed to copy file into Ceph filesystem ${CEPHFS_VFY_FS}"
    return 0
  elif ! local VFY_INTO_CEPHFS_MD5=$(md5sum "${CEPHFS_MNT_PATH}"/"${VFY_TEST_FILE}" | awk '{print $1}') \
    || [ "${VFY_INTO_CEPHFS_MD5}" != "${VFY_MD5}" ]; then
    vlog_red "Wrong checksum when copy into Ceph filesystem ${CEPHFS_VFY_FS} (${VFY_INTO_CEPHFS_MD5})"
    return 0
  elif ! cp "${CEPHFS_MNT_PATH}"/"${VFY_TEST_FILE}" TEST-FILE-FROM-CEPHFS &>/dev/null; then
    vlog_red "Failed to copy file from Ceph filesystem ${CEPHFS_VFY_FS}"
    return 0
  elif ! local VFY_FROM_CEPHFS_MD5=$(md5sum TEST-FILE-FROM-CEPHFS | awk '{print $1}') \
    || [ "${VFY_FROM_CEPHFS_MD5}" != "${VFY_MD5}" ]; then
    vlog_red "Wrong checksum when copy from Ceph filesystem ${CEPHFS_VFY_FS} (${VFY_FROM_CEPHFS_MD5})"
    return 0
  else
    vlog_green "Checksum of Ceph filesystem oprations is correct (${VFY_FROM_CEPHFS_MD5})"
  fi
  # remove file & umount
  if ! rm "${CEPHFS_MNT_PATH}"/"${VFY_TEST_FILE}" &>/dev/null; then
    vlog_red "Failed to remove file from Ceph filesystem ${CEPHFS_VFY_FS}"
    return 0
  elif ! umount "${CEPHFS_MNT_PATH}" &>/dev/null; then
    vlog_red "Failed to umount ${CEPHFS_MNT_PATH}"
    return 0
  else
    vlog_green "Ceph filesystem works well."
  fi
}

function vfy_mds_clean {
  rm TEST-FILE-FROM-CEPHFS &>/dev/null || true
  sleep 2
  timeout 60 umount "${CEPHFS_MNT_PATH}" &>/dev/null || true
}

function remove_test_file {
  if [ -z "${VFY_LIST}" ]; then
    return 0
  fi
  rm "${VFY_TEST_FILE}" &>/dev/null || true
  rm "${VFY_TEST_FILE}".md5 &>/dev/null || true
}

## MAIN
function cdx_verify {
  get_ceph_admin
  get_verify_options
  vfy_cluster
  prepare_test_file
  for item in ${VFY_LIST}; do
    vfy_"${item}"
  done
  remove_test_file
}
