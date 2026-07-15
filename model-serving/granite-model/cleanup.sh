#!/bin/bash

PROJECT=mm-test

oc project "${PROJECT}"
oc delete -f minio.yaml --as system:admin

rm -rf granite-3.0-8b-instruct