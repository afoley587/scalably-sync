#!/bin/bash

AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url=http://localhost:4566 s3api create-bucket --bucket=test

aws --endpoint-url=http://localhost:4566 s3 ls

# Add the bucketname.localhost to /etc/hosts
# 127.0.0.1       localhost test.localhost