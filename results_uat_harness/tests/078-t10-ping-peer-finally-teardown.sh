#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=ping"
oc delete pods,services,deployments -l test=ping --ignore-not-found -n uat-peer
echo "Teardown complete"
