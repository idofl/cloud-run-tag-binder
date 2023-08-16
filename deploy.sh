#!/bin/sh
# Copyright 2023 Google Inc. All Rights Reserved.
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
REGION=[RESOURCE_REGION]
ORG_ID=[ORGANIZATION_ID]
FOLDER_ID=[CLOUD_RUN_ROOT_FOLDER_ID_OR_EMPTY]

# Build the infrastructure using Terraform
# (service accounts, IAM, logging sink, Pub/Sub)

cd terraform

terraform init

terraform apply -auto-approve \
  -var="project_id=$PROJECT_ID" \
  -var="region=$REGION" \
  -var="cloud_run_root_folder=$FOLDER_ID" \
  -var="organization_id=$ORG_ID"

TAG_VALUE=`terraform output -raw tag_value`
SINK_TOPIC=`terraform output -raw sink_topic`
SUBSCRIBER_NAME=`terraform output -raw sink_subscription`
TRIGGER_SERVICE_ACCOUNT=`terraform output -raw trigger_service_account`
FUNCTION_SERVICE_ACCOUNT=`terraform output -raw function_service_account`

cd ..

RUN_SERVICE_NAME=cloud-run-service-tag-binder

# Host the app on Cloud Run
# To view debug logs, change DEBUG_LOGS value to "true"
gcloud run deploy $RUN_SERVICE_NAME \
    --region $REGION \
    --project=$PROJECT_ID \
    --set-env-vars TAG_VALUE=$TAG_VALUE \
    --set-env-vars DEBUG_LOGS="false" \
    --service-account=$FUNCTION_SERVICE_ACCOUNT \
    --quiet \
    --ingress=internal \
    --source src

# Permit the Pub/Sub push subscription to send message to Cloud Run
gcloud run services add-iam-policy-binding $RUN_SERVICE_NAME \
    --project=$PROJECT_ID \
    --region=$REGION \
    --member=serviceAccount:$TRIGGER_SERVICE_ACCOUNT \
    --role="roles/run.invoker"

SERVICE_URL=`gcloud run services describe $RUN_SERVICE_NAME --platform managed --region $REGION --project=$PROJECT_ID --format 'value(status.url)'`

# Change the Pub/Sub subscription from pull to push
gcloud pubsub subscriptions modify-push-config $SUBSCRIBER_NAME \
    --push-endpoint="$SERVICE_URL/projects/$PROJECT_ID/topics/$SINK_TOPIC" \
    --push-auth-service-account=$TRIGGER_SERVICE_ACCOUNT \
    --project=$PROJECT_ID
