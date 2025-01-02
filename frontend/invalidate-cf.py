import boto3
import time
cloudfront_client = boto3.client('cloudfront')
invalidation = cloudfront_client.create_invalidation(
    DistributionId='EAKSINTYP9HI1',
    InvalidationBatch={
        'Paths': {
            'Quantity': 1,
            'Items': ['/*']
        },
        'CallerReference': str(time.time())
    }
)
