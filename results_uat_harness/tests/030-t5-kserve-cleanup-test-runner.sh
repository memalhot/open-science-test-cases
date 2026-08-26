#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=kserve,sweep=test-runner"
oc delete pods,services,deployments -l test=kserve,sweep=test-runner --ignore-not-found -n uat-project
echo "Teardown complete"
