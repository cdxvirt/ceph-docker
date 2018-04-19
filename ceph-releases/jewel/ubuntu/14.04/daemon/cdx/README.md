# CDXVIRT Ceph Daemon

## SERVICE
### MON
```
$ docker run -d --net=host -e CDX_ENV=true -e CEPH_PUBLIC_NETWORK="192.168.0.0/24" \
  -v /var/lib/ceph:/var/lib/ceph cdxvirt/ceph-daemon:latest cdx_mon
```
### OSD
```
$ docker run -d --net=host --privileged=true -e CDX_ENV=true \
  -e DAEMON_VERSION=cdxvirt/ceph-daemon:latest \
  -v /bin/docker:/bin/docker -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/lib64:/host/lib -v /dev:/dev cdxvirt/ceph-daemon:latest cdx_osd
```

### RGW
```
$ docker run -d --net=host -e CDX_ENV=true cdxvirt/ceph-daemon:latest rgw
```

### MDS
```
$ docker run -d --net=host -e CDX_ENV=true cdxvirt/ceph-daemon:latest mds
```

### VERIFY
```
$ docker run -it --net=host --privileged=true -e CDX_ENV=true -e CEPH_VFY=all \
  -e HTTP_VFY_PATH=https://some_ip/some_file -e RGW_VFY_SITE=https://rgw_website \
  -v /lib/modules/:/lib/modules/ -v /dev:/dev cdxvirt/ceph-daemon:latest cdx_verify
```

## TOOLS
### Fix MON
```
$ docker run -it --net=host -e CDX_ENV=true -e MON_RCY=true \
  -e CEPH_PUBLIC_NETWORK="192.168.0.0/24" -v /var/lib/ceph:/var/lib/ceph \
  cdxvirt/ceph-daemon:latest cdx_mon
```

## API
### OSD
```
$ docker exec K8S-OSD-POD ceph-api $OSD-API
```
OSD-API=
- start_all_osds
- stop_all_osds
- restart_all_osds
- get_active_osd_nums
- run_osds

### ETCD
```
$ docker exec ANY-CEPH-K8S-POD ceph-api $ETCD-API
```
ETCD-API=
- set_max_mon $number
- get_max_mon
- set_max_osd $number
- get_max_osd

### FIX MON DOWN
```
$ docker exec ANY-CEPH-K8S-POD ceph-api fix_monitor
```

### CEPH VERIFY
```
$ docker exec ANY-CEPH-K8S-POD ceph-api ceph_verify $OPT1 $OPT2
```
OPTS =>
- CEPH_VFY=all
- CEPH_VFY=rbd,rgw,mds # separate by comma.
- HTTP_VFY_PATH=http://xxx # URL of test file

### CACHE POOL
```
$ docker exec ANY-CEPH-K8S-POD ceph-api get_cache_pool
$ docker exec ANY-CEPH-K8S-POD ceph-api link_cache_tier $TARGET_POOL $CACHE_POOL(optional)
$ docker exec ANY-CEPH-K8S-POD ceph-api unlink_cache_tier $TARGET_POOL $CACHE_POOL(optional)
```

## CDX ENTRYPOINT
### cdx_mon
Before running start_mon, check monip, monmap first.
### cdx_osd
Choose disk, zap disk, and activate disk in different containers.
### cdx_controller
Kubernetes required.Choose nodes to deploy ceph-mon, update endpoints.
### ceph-api
Operate OSD containers.
### admin
Execute other commands.
### cdx_verify
Verify service & function of ceph cluster.

## CDX ENV
### Use CDX_ENV=true to enable it.
### OSD
- CRUSH_TYPE=space
```
# CRUSH TYPE operate number of replications.
# There are "space", "safety" & "none" three modes.
# Space mode sets rbd pool to size 2, and safety mode set to 3.
# none mode won't do any change of crush rules.
```
- PGs_PER_OSD=32
```
# Adjust the pgs of rbd pool.
```
- OSD_INIT_MODE=minimal
```
# OSD INIT MODE is about selecting disk to deploy as OSD.
# There are "minimal", "force" & "strict" three modes about
# First, we won't use any disk that has been mounted.
# Minimal mode selects disks that not Ceph OSD. For example, an OSD disk from other won't be select.
# But if the seleted_list is empty, minimal mode forces to choose one disk.
# Force mode chooses any disks that has no mountpoint.
# Strict mode only select disks that isn't an OSD.
```
- MAX_OSD=1
```
# How many OSD containers in each host?
```
- OSD_MEM=2048M
- OSD_CPU_CORE=2
```
# Resource limits for OSD containers.
```
### MON
- MAX_MON=3
```
# How many MON containers in a cluster?
```
- K8S_NAMESPACE=ceph
- MON_LABEL="cdx/ceph-mon"
```
# Kubernetes MON POD settings.
```
### VERIFY
- CEPH_VFY=all
```
# Items for varifying, separate by comma.
# e.g. CEPH_VFY=rbd,rgw,mds
```
- RBD_VFY_POOL=rbd
```
# Default pool for ceph verifying
```
- CEPHFS_VFY_FS=cephfs
```
# Default ceph filesystem name for ceph verifying
```
- RGW_VFY_PORT=${RGW_CIVETWEB_PORT}=18080
```
# Default RGW website port
```
- RGW_VFY_SITE=
```
# Which RGW website is going to verify?
# If RGW_VFY_SITE is null, then find IP from kubernetes.
```
- HTTP_VFY_PATH=
```
# You can assign a file by giving url for verifying.
```
