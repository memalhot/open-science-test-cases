#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Cleaning up all UAT resources..."
oc delete pods -l app.kubernetes.io/managed-by=uat-generator --ignore-not-found -n uat-peer
oc delete services -l app.kubernetes.io/managed-by=uat-generator --ignore-not-found -n uat-peer
oc delete deployments -l app.kubernetes.io/managed-by=uat-generator --ignore-not-found -n uat-peer
oc delete configmap uat-test-source --ignore-not-found -n uat-peer
echo "Cleanup complete"
