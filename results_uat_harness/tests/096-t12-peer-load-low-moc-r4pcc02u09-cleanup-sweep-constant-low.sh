#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=peer-load-low,node=moc-r4pcc02u09,sweep=constant-low"
oc delete pods,services,deployments -l test=peer-load-low,node=moc-r4pcc02u09,sweep=constant-low --ignore-not-found -n uat-project
echo "Teardown complete"
