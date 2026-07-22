#!/bin/bash

PROJECT=${PROJECT:-mm-test}

oc project "${PROJECT}"

echo "Deleting Open WebUI..."
oc process -f yaml/open-webui.yaml \
  -p MODEL_URL=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

echo "Cleanup complete."
