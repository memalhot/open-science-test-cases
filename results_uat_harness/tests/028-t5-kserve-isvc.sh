#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t5-kserve-isvc.yaml..."
oc apply -f manifests/t5-kserve-isvc.yaml -n uat-project
echo "Applied manifests/t5-kserve-isvc.yaml"
