#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=platform-check,sweep=checker"
oc delete pods,services,deployments -l test=platform-check,sweep=checker --ignore-not-found -n uat-project
echo "Teardown complete"
