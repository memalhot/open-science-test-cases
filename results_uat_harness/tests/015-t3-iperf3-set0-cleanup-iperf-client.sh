#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Tearing down resources with selector: test=iperf3,chain=set0,sweep=iperf-client"
oc delete pods,services,deployments -l test=iperf3,chain=set0,sweep=iperf-client --ignore-not-found -n uat-project
echo "Teardown complete"
