#!/bin/bash
source scale.sh

if [ -z $1 ]; then
  echo "No argument"
  exit 1
fi

if [ $1 == "init" ]; then
  etcdctl exec-watch /ceph-config/ceph/max_osd_num_per_node -- /bin/bash -c '/bin/bash /etcd-watcher.sh \"$ETCD_WATCH_VALUE\"'
else
  max_osd_num=$ETCD_WATCH_VALUE
  echo "max_osd_num: $max_osd_num"

  ceph-api run_osds
fi


