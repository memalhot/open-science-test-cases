#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=guidellm,node=moc-r4pcc02u05,sweep=pass-fail"
oc delete pods,services,deployments -l test=guidellm,node=moc-r4pcc02u05,sweep=pass-fail --ignore-not-found -n uat-project
echo "Teardown complete"
