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

# The below variables should be set before calling this script
if [[ -z $PROJECT_ID || -z $REGION || -z $ORG_ID ]]; then
  echo "Please set the following variables before calling the script: PROJECT_ID, REGION, ORG_ID, FOLDER_ID (optional)."
  exit 1
fi

gcloud config set project $PROJECT_ID

if [[ -z $FOLDER_ID ]]; then
  parameter_name="organization"
  parameter_value=$ORG_ID
else
  parameter_name="folder"
  parameter_value=$FOLDER_ID
fi

# Backup the org policy at either the org or folder level
policyFound=`gcloud org-policies list --filter="iam.allowedPolicyMemberDomains" --$parameter_name=$parameter_value`
if [[ policyFound ]]; then
  gcloud org-policies describe iam.allowedPolicyMemberDomains \
    --$parameter_name=$parameter_value > originOrgPolicy.yaml
fi

# Build the infrastructure using Terraform
# (service accounts, IAM, logging sink, Pub/Sub)

cd terraform

terraform init

# Import existing org policy to Terraform's state
# To enable Terraform to calculate the diff
if [[ policyFound ]]; then
  terraform import \
    -var="project_id=$PROJECT_ID" \
    -var="region=$REGION" \
    -var="cloud_run_root_folder=$FOLDER_ID" \
    -var="organization_id=$ORG_ID" \
    google_org_policy_policy.drs_org_policy "${parameter_name}s/$parameter_value/policies/iam.allowedPolicyMemberDomains"
fi

terraform apply -auto-approve \
  -var="project_id=$PROJECT_ID" \
  -var="region=$REGION" \
  -var="cloud_run_root_folder=$FOLDER_ID" \
  -var="organization_id=$ORG_ID"

TAG_VALUE=`terraform output -raw tag_value`
SINK_TOPIC=`terraform output -raw sink_topic`
TRIGGER_SERVICE_ACCOUNT=`terraform output -raw trigger_service_account`
APP_SERVICE_ACCOUNT=`terraform output -raw app_service_account`

cd ..

RUN_SERVICE_NAME=cloud-run-service-tag-binder
EVENTARC_TRIGGER_NAME=events-pubsub-trigger

# Host the app on Cloud Run
# To view debug logs, change DEBUG_LOGS value to "true"
gcloud run deploy $RUN_SERVICE_NAME \
    --region $REGION \
    --project=$PROJECT_ID \
    --set-env-vars TAG_VALUE=$TAG_VALUE \
    --set-env-vars DEBUG_LOGS="false" \
    --service-account=$APP_SERVICE_ACCOUNT \
    --quiet \
    --ingress=internal \
    --source src

# Permit the Pub/Sub push subscription to send message to Cloud Run
gcloud run services add-iam-policy-binding $RUN_SERVICE_NAME \
    --project=$PROJECT_ID \
    --region=$REGION \
    --member=serviceAccount:$TRIGGER_SERVICE_ACCOUNT \
    --role="roles/run.invoker"

gcloud eventarc triggers create $EVENTARC_TRIGGER_NAME \
    --project=$PROJECT_ID \
    --location=$REGION \
    --destination-run-service=$RUN_SERVICE_NAME \
    --destination-run-region=$REGION \
    --event-filters="type=google.cloud.pubsub.topic.v1.messagePublished" \
    --transport-topic=projects/$PROJECT_ID/topics/$SINK_TOPIC \
    --service-account=$TRIGGER_SERVICE_ACCOUNT