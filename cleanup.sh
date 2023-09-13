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
#PROJECT_ID=[APP_PROJECT_ID]
#REGION=[APP_REGION]
#ORG_ID=[ORGANIZATION_ID]
#FOLDER_ID=[ROOT_FOLDER_ID]

# Remove the service tagging application

RUN_SERVICE_NAME=cloud-run-service-tag-binder
EVENTARC_TRIGGER_NAME=events-pubsub-trigger

gcloud run services delete $RUN_SERVICE_NAME \
    --region $REGION \
    --project=$PROJECT_ID \
    --quiet

gcloud eventarc triggers delete $EVENTARC_TRIGGER_NAME \
  --project=$PROJECT_ID \
  --location=$REGION \

# Remove all the components created by terraform
cd terraform

terraform destroy -auto-approve \
  -var="project_id=$PROJECT_ID" \
  -var="region=$REGION" \
  -var="cloud_run_root_folder=$FOLDER_ID" \
  -var="organization_id=$ORG_ID"

cd ..

