#!/bin/bash
set -euo pipefail

MY_WORKBENCH=mm-test

oc project "${MY_WORKBENCH}"
oc apply -f minio.yaml --as system:admin

if [[ ! -f credentials.env ]]; then
  echo "Error: credentials.env not found" >&2
  exit 1
fi
source credentials.env

S3_ENDPOINT=$(oc get route minio-api -o jsonpath='https://{.spec.host}')
if [[ -z "${S3_ENDPOINT}" ]]; then
  echo "Error: failed to get minio-api route" >&2
  exit 1
fi
export S3_ENDPOINT

git clone "https://memalhot:${ACCESS_TOKEN}@huggingface.co/ibm-granite/granite-3.0-8b-instruct"
python create-bucket.py
python model-to-s3.py