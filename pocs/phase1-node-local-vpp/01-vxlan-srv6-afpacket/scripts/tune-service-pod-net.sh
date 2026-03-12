#!/bin/bash
set -euo pipefail

POD_NAME=${1:-phase1-service-a}
POD_NAMESPACE=${POD_NAMESPACE:-default}
DATAPLANE_GW=${DATAPLANE_GW:-10.20.0.254}

kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" -- sh -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y ethtool >/dev/null
ip route add 10.50.0.0/30 via '"$DATAPLANE_GW"' dev net1 2>/dev/null || true
ethtool -K net1 tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
echo "service dataplane route:"
ip route | grep 10.50.0.0/30 || true
echo "service dataplane offloads:"
ethtool -k net1 | egrep "tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|tx-checksumming|rx-checksumming"
'