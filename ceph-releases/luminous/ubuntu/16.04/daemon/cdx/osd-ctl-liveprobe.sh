#!/bin/bash
set -e

if ! pidof etcdctl; then
  echo "Not found etcdctl"
  exit 1
fi

if ! pidof inotifywait; then
  echo "Not found inotifywait"
  exit 1
fi
