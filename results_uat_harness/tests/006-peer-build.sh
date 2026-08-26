#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Executing on ginkgo-builder: bash /src/build.sh"
oc exec ginkgo-builder -n uat-peer -- bash /src/build.sh
echo "Done"
