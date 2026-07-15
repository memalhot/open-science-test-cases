import os
import boto3
import botocore
from dotenv import load_dotenv

load_dotenv('credentials.env')

S3_ENDPOINT = os.environ['S3_ENDPOINT']
ACCESS_KEY = os.environ['MINIO_ROOT_USER']
SECRET_KEY = os.environ['MINIO_ROOT_PASSWORD']
BUCKET_NAME = 'models'

s3_resource = boto3.resource(
    's3',
    endpoint_url=S3_ENDPOINT,
    aws_access_key_id=ACCESS_KEY,
    aws_secret_access_key=SECRET_KEY,
    region_name='us-east-1',
    config=botocore.client.Config(signature_version='s3v4')
)

bucket = s3_resource.Bucket(BUCKET_NAME)

try:
    bucket.objects.all().delete()
    print(f"Deleted all objects in bucket '{BUCKET_NAME}'.")
    bucket.delete()
    print(f"Deleted bucket '{BUCKET_NAME}'.")
except botocore.exceptions.ClientError as e:
    print(f"Error cleaning up bucket: {e}")
