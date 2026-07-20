#!/bin/bash

PROJECT=mm-test
MODEL_NAME=granite-model

oc project "${PROJECT}"

if [[ -f credentials.env ]]; then
  source credentials.env
fi

# Delete the external route and service
echo "Deleting external route and service..."
oc delete route "${MODEL_NAME}" -n "${PROJECT}" --as system:admin --ignore-not-found
oc delete service "${MODEL_NAME}-external" -n "${PROJECT}" --as system:admin --ignore-not-found

# Delete the InferenceService
echo "Deleting InferenceService..."
oc process -f yaml/inference-service.yaml \
  -p SERVING_RUNTIME=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

# Delete the ServingRuntime
echo "Deleting ServingRuntime..."
oc delete -f yaml/serving-runtime.yaml --as system:admin --ignore-not-found

# Delete the data connection
echo "Deleting data connection..."
oc process -f yaml/data-connection.yaml \
  -p MINIO_ROOT_USER=placeholder \
  -p MINIO_ROOT_PASSWORD=placeholder \
  -p S3_ENDPOINT=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

# Delete the S3 bucket contents
echo "Deleting S3 bucket..."
S3_ENDPOINT=$(oc get route minio-api -n "${PROJECT}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
if [[ -n "${S3_ENDPOINT}" ]]; then
  export S3_ENDPOINT
  python python/delete-bucket.py
else
  echo "Warning: MinIO route not found, skipping bucket deletion"
fi

# Delete MinIO
echo "Deleting MinIO..."
oc process -f yaml/minio.yaml \
  -p MINIO_ROOT_USER=placeholder \
  -p MINIO_ROOT_PASSWORD=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

# Remove namespace label
echo "Removing namespace label..."
oc label namespace "${PROJECT}" modelmesh-enabled- --as system:admin 2>/dev/null || true

# Clean up local model files
rm -rf granite-3.0-8b-instruct

echo "Cleanup complete."
