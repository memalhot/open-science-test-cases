#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=kserve"
oc delete pods,services,deployments,InferenceService -l test=kserve --ignore-not-found -n uat-project
echo "Teardown complete"
