#!/bin/bash

USAGE="Usage: $0 [ceph_namespace] [ceph-mon-label] [secret_namespace]

ceph_namespace default: ceph
ceph-mon-label default: ceph-mon
secret_namespace default: default
"

  while getopts ":h" OPTION
  do
    case $OPTION in
      h) echo "$USAGE"; exit;;
    esac
  done

  if [ -z $1 ]; then
     NAMESPACE="default"
  else
     NAMESPACE="$1"
  fi
  if [ -z $2 ]; then
     LABLE="ceph-mon"
  else
     LABLE="$2"
  fi
  if [ -z $3 ]; then
     SECRET_NAMESPACE="default"
  else
     SECRET_NAMESPACE="$3"
  fi

  command -v kubectl > /dev/null 2>&1 || { echo "Command not found: kubectl"; exit 1; }
  KUBECTL=$(command -v kubectl)

  POD=$( $KUBECTL --namespace=$NAMESPACE get pod -l name=$LABLE | awk 'NR==2{print$1}')

  if [ ! -z $POD ]; then
    KEY=$( $KUBECTL exec -it $POD grep key /etc/ceph/ceph.client.admin.keyring |awk '{printf "%s", $NF}'|base64 )

    sed "s/\$SECRET_NAMESPACE/${SECRET_NAMESPACE}/g" ceph-secrets.yaml.template | sed "s/\$KEY/${KEY}/g" > ceph-secrets.yaml

  else
    echo "ceph-mon not found"
  fi
