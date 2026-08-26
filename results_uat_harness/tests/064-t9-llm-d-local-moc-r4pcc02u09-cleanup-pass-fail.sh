#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=llm-d-local,node=moc-r4pcc02u09,sweep=pass-fail"
oc delete pods,services,deployments -l test=llm-d-local,node=moc-r4pcc02u09,sweep=pass-fail --ignore-not-found -n uat-project
echo "Teardown complete"
