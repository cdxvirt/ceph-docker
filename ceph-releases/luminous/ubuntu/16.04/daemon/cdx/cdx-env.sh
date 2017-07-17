#!/bin/bash

: "${KV_TYPE:=etcd}"
: "${KV_IP:=127.0.0.1}"
: "${KV_PORT:=2379}"
: "${OSD_BLUESTORE:=1}"
: "${MAX_OSD:=3}"
: "${CEPHFS_CREATE:=1}"
: "${CEPHFS_DATA_POOL_PG:=32}"
: "${CEPHFS_METADATA_POOL_PG:=32}"
: "${RGW_CIVETWEB_PORT:=18080}"
