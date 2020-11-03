#!/usr/bin/env bash

STACK_NAME='kendra-demo'

if ! command -v jq &> /dev/null
then
    echo "jq could not be found"
    exit
fi

if ! command -v aws &> /dev/null
then
    echo "aws could not be found"
    exit
fi

echo "Creating stack..."
STACK_ID=$( aws cloudformation create-stack --stack-name ${STACK_NAME} \
  --template-body file://build-kendra.yml \
  --capabilities CAPABILITY_IAM \
  | jq -r .StackId \
)

echo "Waiting on ${STACK_ID} create completion..."
aws cloudformation wait stack-create-complete --stack-name ${STACK_ID}
CFN_OUTPUT=$(aws cloudformation describe-stacks --stack-name ${STACK_ID} | jq .Stacks[0].Outputs)

BUCKET=$(echo $CFN_OUTPUT | jq '.[]| select(.OutputKey | contains("S3BucketName")).OutputValue' -r)
DATASOURCE_ID=$(echo $CFN_OUTPUT | jq '.[]| select(.OutputKey | contains("DataSourceId")).OutputValue' -r)
S3_ARN=$(echo $CFN_OUTPUT | jq '.[]| select(.OutputKey | contains("KendraS3Arn")).OutputValue' -r)
IFS='|' read -a datasource <<< "${DATASOURCE_ID}"

echo "Uploading files to bucket"
aws s3 sync content/ s3://${BUCKET}/content

echo "Indexing content"
OUTPUT=$(aws kendra start-data-source-sync-job --id ${datasource[0]} --index-id ${datasource[1]})
INDEX_OUTPUT=$(aws kendra describe-data-source --id ${datasource[0]} --index-id ${datasource[1]} | jq '.Status' -r)
while [ "$INDEX_OUTPUT" != "ACTIVE" ]; do
    sleep 30
    INDEX_OUTPUT=$(aws kendra describe-data-source --id ${datasource[0]} --index-id ${datasource[1]} | jq '.Status' -r)
done 

echo "Adding FAQ"
aws s3 sync faq/ s3://${BUCKET}/faq

STACK_ID=$( aws cloudformation create-stack --stack-name "${STACK_NAME}-FAQ" \
  --template-body file://kendra-faq.yml \
  --capabilities CAPABILITY_IAM \
  --parameters ParameterKey=RoleArn,ParameterValue=${S3_ARN} \
               ParameterKey=KendraIndex,ParameterValue=${datasource[1]} \
               ParameterKey=KendraS3Bucket,ParameterValue=${BUCKET} \
  | jq -r .StackId \
)
aws cloudformation wait stack-create-complete --stack-name ${STACK_ID}

echo "Kendra is now set up. Go to the console to see it in action!"