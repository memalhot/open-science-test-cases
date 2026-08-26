#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=ping,sweep=peer-check"
oc delete pods,services,deployments -l test=ping,sweep=peer-check --ignore-not-found -n uat-peer
echo "Teardown complete"
