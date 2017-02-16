# DOCKER-VERSION 1.0.0
#
# Ceph Daemon
#
# VERSION 0.0.1

FROM cdxvirt/ceph-base:10.2.5-1
MAINTAINER Sébastien Han "seb@redhat.com"

# Add templates for confd
ADD ./confd/templates/* /etc/confd/templates/
ADD ./confd/conf.d/* /etc/confd/conf.d/

# Add bootstrap script, ceph defaults key/values for KV store
ADD entrypoint.sh config.*.sh ceph.defaults check_zombie_mons.py remove-mon.sh scale.sh etcd-watcher.sh liveprobe.sh secret-template/create-ceph-secrets.sh secret-template/ceph-secrets.yaml.template /
ADD ceph-api /usr/bin/ceph-api


# Add volumes for Ceph config and data
VOLUME ["/etc/ceph","/var/lib/ceph", "/etc/ganesha"]

# Execute the entrypoint
WORKDIR /
ENTRYPOINT ["/entrypoint.sh"]
