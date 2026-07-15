import os
import boto3
import botocore
from dotenv import load_dotenv

load_dotenv('credentials.env')

S3_ENDPOINT = os.environ['S3_ENDPOINT']
ACCESS_KEY = os.environ['MINIO_ROOT_USER']
SECRET_KEY = os.environ['MINIO_ROOT_PASSWORD']
BUCKET_NAME = 'models'

s3_client = boto3.client(
    's3',
    endpoint_url=S3_ENDPOINT,
    aws_access_key_id=ACCESS_KEY,
    aws_secret_access_key=SECRET_KEY,
    region_name='us-east-1',
    config=botocore.client.Config(signature_version='s3v4')
)

try:
    s3_client.head_bucket(Bucket=BUCKET_NAME)
    print(f"Bucket '{BUCKET_NAME}' already exists.")
except botocore.exceptions.ClientError:
    s3_client.create_bucket(Bucket=BUCKET_NAME)
    print(f"Bucket '{BUCKET_NAME}' created.")
