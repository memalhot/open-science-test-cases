#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Executing on uat-aggregator: python /src/aggregate.py /uat_workspace"
oc exec uat-aggregator -n uat-project -- python /src/aggregate.py /uat_workspace
echo "Done"
