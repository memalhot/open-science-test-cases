#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/apply-configmap.yaml..."
oc apply -f manifests/apply-configmap.yaml -n uat-project
echo "Applied manifests/apply-configmap.yaml"
