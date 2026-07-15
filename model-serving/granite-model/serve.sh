#!/bin/bash
set -euo pipefail

PROJECT=mm-test

if [[ ! -f credentials.env ]]; then
  echo "Error: credentials.env not found" >&2
  exit 1
fi
source credentials.env

oc project "${PROJECT}"
oc process -f minio.yaml \
  -p MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -p MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  | oc apply --as system:admin -f -
oc wait --for=condition=available deployment/minio --timeout=120s

S3_ENDPOINT=$(oc get route minio-api -o jsonpath='https://{.spec.host}')
if [[ -z "${S3_ENDPOINT}" ]]; then
  echo "Error: failed to get minio-api route" >&2
  exit 1
fi
export S3_ENDPOINT

git clone "https://memalhot:${ACCESS_TOKEN}@huggingface.co/ibm-granite/granite-3.0-8b-instruct"
sleep 3

python create-bucket.py
sleep 3

python model-to-s3.py