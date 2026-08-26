#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=ping,sweep=project-check"
oc delete pods,services,deployments -l test=ping,sweep=project-check --ignore-not-found -n uat-project
echo "Teardown complete"
