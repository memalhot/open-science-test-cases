import os
import boto3
import botocore
from dotenv import load_dotenv

load_dotenv('credentials.env')

# ----------------- Configuration -----------------
ACCESS_KEY = os.environ['MINIO_ROOT_USER']
SECRET_KEY = os.environ['MINIO_ROOT_PASSWORD']
S3_ENDPOINT = os.environ['S3_ENDPOINT']
REGION_NAME = 'us-east-1'
BUCKET_NAME = 'models'

if not all([ACCESS_KEY, SECRET_KEY, S3_ENDPOINT, REGION_NAME, BUCKET_NAME]):
    raise ValueError(
        "One or more S3 connection variables are empty. "
        "Please check your S3 configuration."
    )

# ----------------- Initialize S3 -----------------
session = boto3.session.Session(
    aws_access_key_id=ACCESS_KEY,
    aws_secret_access_key=SECRET_KEY
)

s3_resource = session.resource(
    's3',
    endpoint_url=S3_ENDPOINT,
    region_name=REGION_NAME,
    config=botocore.client.Config(signature_version='s3v4')
)

bucket = s3_resource.Bucket(BUCKET_NAME)

# ----------------- Helper Functions -----------------
def ensure_s3_prefix_exists(bucket, prefix: str):
    """
    Ensure an S3 prefix exists by creating a zero-byte object
    if no objects already exist under the prefix.
    """
    prefix = prefix.rstrip("/") + "/"
    objs = list(bucket.objects.filter(Prefix=prefix))
    if not objs:
        bucket.put_object(Key=prefix)
        print(f"Created S3 prefix: {prefix}")
    else:
        print(f"S3 prefix already exists: {prefix}")


def upload_file_to_s3(local_file: str, s3_prefix: str):
    """
    Upload a single file to S3 under the specified prefix.
    """
    filename = os.path.basename(local_file)
    s3_key = os.path.join(s3_prefix, filename).replace("\\", "/")
    print(f"Uploading {local_file} -> {s3_key}")
    bucket.upload_file(local_file, s3_key)
    return 1


def upload_directory_to_s3(local_directory: str, s3_prefix: str):
    """
    Upload all files from a local directory to S3 under the given prefix.
    Preserves folder structure.
    """
    num_files = 0
    for root, _, files in os.walk(local_directory):
        for filename in files:
            file_path = os.path.join(root, filename)
            relative_path = os.path.relpath(file_path, local_directory)
            s3_key = os.path.join(s3_prefix, relative_path).replace("\\", "/")
            print(f"Uploading {file_path} -> {s3_key}")
            bucket.upload_file(file_path, s3_key)
            num_files += 1
    return num_files


def list_objects(prefix: str):
    """List all objects under the given S3 prefix."""
    for obj in bucket.objects.filter(Prefix=prefix):
        print(obj.key)


# ----------------- Main Logic -----------------
LOCAL_MODELS_DIR = "granite-3.0-8b-instruct"
S3_MODELS_PREFIX = "models/granite-3.0-8b-instruct"

if not os.path.isdir(LOCAL_MODELS_DIR):
    raise ValueError(
        f"The directory '{LOCAL_MODELS_DIR}' does not exist. "
        "Did you finish downloading or training the model?"
    )

# Ensure S3 "directory" exists
ensure_s3_prefix_exists(bucket, S3_MODELS_PREFIX)

# Upload all model files
num_files_uploaded = upload_directory_to_s3(LOCAL_MODELS_DIR, S3_MODELS_PREFIX)

if num_files_uploaded == 0:
    raise ValueError(
        "No files were uploaded. Did you finish saving the model to the directory?"
    )

print(f"Successfully uploaded {num_files_uploaded} files to S3.")