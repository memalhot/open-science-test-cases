#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=component,node=moc-r4pcc02u09,sweep=test-runner"
oc delete pods,services,deployments -l test=component,node=moc-r4pcc02u09,sweep=test-runner --ignore-not-found -n uat-project
echo "Teardown complete"
