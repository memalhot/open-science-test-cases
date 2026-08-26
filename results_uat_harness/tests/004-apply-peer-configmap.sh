#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/apply-peer-configmap.yaml..."
oc apply -f manifests/apply-peer-configmap.yaml -n uat-peer
echo "Applied manifests/apply-peer-configmap.yaml"
