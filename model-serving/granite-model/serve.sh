#!/bin/bash

MY_WORKBENCH=mm-test

oc project ${MY_WORKBENCH}
oc apply -f mino.yaml --as system:admin
source credentials.env
S3_ENDPOINT=$(oc get route minio-api -o jsonpath='https://{.spec.host}')
export S3_ENDPOINT
git clone https://memalhot:${ACCESS_TOKEN}@huggingface.co/ibm-granite/granite-3.0-8b-instruct
python create-bucket.py
python model-to-s3.py