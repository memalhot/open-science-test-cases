#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Executing on peer-uat-aggregator: python /src/aggregate.py /uat_workspace"
oc exec peer-uat-aggregator -n uat-peer -- python /src/aggregate.py /uat_workspace
echo "Done"
