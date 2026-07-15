#!/bin/bash

PROJECT=mm-test

oc project "${PROJECT}"

oc process -f yaml/inference-service.yaml \
  -p SERVING_RUNTIME=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

oc process -f yaml/data-connection.yaml \
  -p MINIO_ROOT_USER=placeholder \
  -p MINIO_ROOT_PASSWORD=placeholder \
  -p S3_ENDPOINT=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

python python/delete-bucket.py

oc process -f yaml/minio.yaml \
  -p MINIO_ROOT_USER=placeholder \
  -p MINIO_ROOT_PASSWORD=placeholder \
  | oc delete --as system:admin -f -

rm -rf granite-3.0-8b-instruct