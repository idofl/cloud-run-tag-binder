#!/bin/sh
# Copyright 2022 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

PROJECT_ID=[FUNCTION_PROJECT_ID]
FOLDER_ID=[INSPECTED_FOLDER_ID]
REGION=[RESOURCE_REGION]

FUNCTION_SERVICE_ACCOUNT_NAME=cloud-run-tag-binder
TRIGGER_SERVICE_ACCOUNT_NAME=cloud-run-notifier
FUNCTION_SERVICE_ACCOUNT=$FUNCTION_SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com
TRIGGER_SERVICE_ACCOUNT=$TRIGGER_SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com

SINK_NAME=cloud-run-create-service-sink
TAG_NAME=AllowPublicAccess

PROJECT_NUMBER=`gcloud projects describe $PROJECT_ID --format="value(projectNumber)"`
ORG_ID=`gcloud projects get-ancestors $PROJECT_ID --format=json | jq -c '.[] | select(.type=="organization") | .id | tonumber'`

gcloud services enable \
  cloudresourcemanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  logging.googleapis.com \
  cloudbuild.googleapis.com \
  pubsub.googleapis.com \
  eventarc.googleapis.com \
  orgpolicy.googleapis.com \
  --project $PROJECT_ID

gcloud resource-manager tags keys create $TAG_NAME \
  --parent=organizations/$ORG_ID

gcloud resource-manager tags values create true \
  --parent=$ORG_ID/$TAG_NAME

TAG_VALUE=`gcloud resource-manager tags values describe $ORG_ID/$TAG_NAME/true \
  --format="value(name)"`

tee allowPublicAccessPolicy.json <<EOF
{
  "name": "folders/$FOLDER_ID/policies/iam.allowedPolicyMemberDomains",
  "spec": {
    "inheritFromParent": true,
    "rules": [
      {
        "allowAll": true,
        "condition": {
          "expression": "resource.matchTag(\"$ORG_ID/$TAG_NAME\", \"true\")",
          "title": "allow"
        }
      }
    ]
  }
}
EOF

gcloud org-policies set-policy allowPublicAccessPolicy.json \
    --billing-project $PROJECT_ID

gcloud iam service-accounts create $FUNCTION_SERVICE_ACCOUNT_NAME \
  --display-name="Service account with permissions to bind tag value to Cloud Run services" \
  --project=$PROJECT_ID

gcloud iam service-accounts create $TRIGGER_SERVICE_ACCOUNT_NAME \
  --display-name="Service account with permissions to invoke the Cloud Run services" \
  --project=$PROJECT_ID

gcloud iam roles create runTagBinder \
  --organization=$ORG_ID \
  --title="Cloud Run Tag Binder" \
  --stage=GA \
  --description="Have access to create tag bindings for cloud run services" \
  --permissions=run.services.createTagBinding

gcloud resource-manager tags values add-iam-policy-binding $TAG_VALUE \
  --member="serviceAccount:${FUNCTION_SERVICE_ACCOUNT}" \
  --role='roles/resourcemanager.tagUser'

gcloud resource-manager folders add-iam-policy-binding $FOLDER_ID \
  --member="serviceAccount:${FUNCTION_SERVICE_ACCOUNT}" \
  --role="organizations/$ORG_ID/roles/runTagBinder"

gcloud iam service-accounts add-iam-policy-binding $TRIGGER_SERVICE_ACCOUNT \
  --project=$PROJECT_ID \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role='roles/iam.serviceAccountTokenCreator'

# Sink to PubSub
SINK_TOPIC=cloud-run-logs
SINK_DESTINATION=pubsub.googleapis.com/projects/$PROJECT_ID/topics/$SINK_TOPIC

gcloud pubsub topics create $SINK_TOPIC \
  --project $PROJECT_ID

# Create sink
gcloud logging sinks create $SINK_NAME \
  $SINK_DESTINATION \
  --description="Cloud Run Create Service sink" \
  --include-children \
  --folder=$FOLDER_ID \
  --log-filter='LOG_ID("cloudaudit.googleapis.com/activity") AND
protoPayload.methodName="google.cloud.run.v1.Services.CreateService" AND
resource.type="cloud_run_revision"'

SINK_IDENTITY=`gcloud logging sinks describe $SINK_NAME \
  --folder ${FOLDER_ID} \
  --format="value(writerIdentity)"`

# Permit sink identity to publish to the topic
gcloud pubsub topics add-iam-policy-binding $SINK_TOPIC \
  --member=$SINK_IDENTITY \
  --role='roles/pubsub.publisher' \
  --project=$PROJECT_ID

# gcloud will attempt by default to create a bucket in the US.
# If gcloud fails with a location violation, then run the following to 
# create a bucket in $REGION to avoid creating in the US.
gcloud storage buckets create gs://${PROJECT_ID}_cloudbuild \
    --location $REGION \
    --project $PROJECT_ID

# Host the app on Cloud Run
RUN_SERVICE_NAME=cloud-run-service-tag-binder
gcloud run deploy $RUN_SERVICE_NAME \
    --region $REGION \
    --project=$PROJECT_ID \
    --set-env-vars TAG_VALUE=$TAG_VALUE \
    --set-env-vars DEBUG="true" \
    --service-account=$FUNCTION_SERVICE_ACCOUNT \
    --quiet \
    --ingress=internal \
    --source .

# Permit Pub/Sub push subscription to send message to Cloud Run 
gcloud run services add-iam-policy-binding $RUN_SERVICE_NAME \
    --project=$PROJECT_ID \
    --region=$REGION \
    --member=serviceAccount:$TRIGGER_SERVICE_ACCOUNT \
    --role=roles/run.invoker

SERVICE_URL=`gcloud run services describe $RUN_SERVICE_NAME --platform managed --region $REGION --project=$PROJECT_ID --format 'value(status.url)'`

# Create a push subscriber in Pub/Sub
gcloud pubsub subscriptions create $RUN_SERVICE_NAME-subscriber \
    --topic $SINK_TOPIC \
    --ack-deadline=600 \
    --push-endpoint="$SERVICE_URL/projects/$PROJECT_ID/topics/$SINK_TOPIC" \
    --push-auth-service-account=$TRIGGER_SERVICE_ACCOUNT \
    --project=$PROJECT_ID

# TEST_PROJECT_ID=[TEST_PROJECT_ID]
# gcloud run deploy hello \
#   --image=us-docker.pkg.dev/cloudrun/container/hello@sha256:2e70803dbc92a7bffcee3af54b5d264b23a6096f304f00d63b7d1e177e40986c \
#   --region=$REGION \
#   --allow-unauthenticated \
#   --ingress=internal \
#   --project=$TEST_PROJECT_ID
