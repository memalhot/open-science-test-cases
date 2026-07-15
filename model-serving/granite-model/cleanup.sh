#!/bin/bash

PROJECT=mm-test

oc project "${PROJECT}"
python delete-bucket.py

oc process -f minio.yaml \
  -p MINIO_ROOT_USER=placeholder \
  -p MINIO_ROOT_PASSWORD=placeholder \
  | oc delete --as system:admin -f -

rm -rf granite-3.0-8b-instruct