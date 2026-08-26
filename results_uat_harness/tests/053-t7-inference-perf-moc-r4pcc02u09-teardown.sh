#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=inference-perf,node=moc-r4pcc02u09"
oc delete pods,services,deployments -l test=inference-perf,node=moc-r4pcc02u09 --ignore-not-found -n uat-project
echo "Teardown complete"
