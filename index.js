// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
'use strict';

const {TagBindingsClient} = require('@google-cloud/resource-manager');
const functions = require('@google-cloud/functions-framework');

const LOG_DEBUG = process.env.DEBUG;

function debugLog(message) {
  if (LOG_DEBUG) {console.log(message);}
}

async function callCreateTagBinding(projectId, location, serviceName) {
  // Get parameters from env variables
  var tagValue = process.env.TAG_VALUE;
  if (!tagValue) {
    console.error("TAG_VALUE environment variable is missing. Specify value in the format tagValues/TAG_ID");
    throw new Error("Missing argument: TAG_VALUE");
  }

  const resourceId = `//run.googleapis.com/projects/${projectId}/locations/${location}/services/${serviceName}`;

  // Construct request
  const request = {
    tagBinding : {
      parent: resourceId,
      tagValue: tagValue
    }
  };
  console.log(`Applying tag '${request.tagBinding.tagValue}' to resource '${request.tagBinding.parent}'`);

  // Create a regional client because the tag binding is for a regional resource
  // (a Cloud Run service)
  const resourcemanagerClient = new TagBindingsClient(
  {
    apiEndpoint:`${location}-cloudresourcemanager.googleapis.com`,
  });

  // Run request
  const [operation] = await resourcemanagerClient.createTagBinding(request).catch(err => {
    debugLog(JSON.stringify(err));
    // For perimssions issues, provide more information via log
    if (err.code && err.code == 7 && err.details && err.details == 'The caller does not have permission') {
      console.error('Function is not permitted to read tag value or bind the tag to the service. Make sure the service account is permitted to both the tag and the resource');
      throw new Error(err.details);
    }
  });

  const [response] = await operation.promise();
  debugLog(JSON.stringify(response));
}

function parseLogCloudEvent(cloudEvent) {
  // Example structure
  // https://googleapis.github.io/google-cloudevents/examples/binary/audit/LogEntryData-pubsubCreateTopic.json
  const payload = cloudEvent.data && cloudEvent.data.resource;
  let labels = payload && payload.labels;

  return labels;
}

function parsePubSubCloudEvent(cloudEvent) {
  // Example structure:
  // https://googleapis.github.io/google-cloudevents/examples/binary/pubsub/MessagePublishedData-complex.json
  const data = cloudEvent.data.message.data;
  let message = Buffer.from(data, 'base64').toString().trim();
  message = JSON.parse(message);
  let labels = message.resource && message.resource.labels;

  return labels;
}

functions.cloudEvent('cloudRunServiceCreatedEvent', async(cloudEvent) => {
  debugLog(JSON.stringify(cloudEvent));
  
  // Extract parameters from the CloudEvent
  // https://cloud.google.com/eventarc/docs/cloudevents#common-events
  if (cloudEvent.type == 'google.cloud.audit.log.v1.written') {
    var labels = parseLogCloudEvent(cloudEvent);
  } 
  else if (cloudEvent.type == 'google.cloud.pubsub.topic.v1.messagePublished') {
    var labels = parsePubSubCloudEvent(cloudEvent);
  } else {
    console.error(`Unsupported Eventarc source: ${cloudEvent.type}`);
    throw new Error('Unsupported Eventarc source');
  }

  debugLog(JSON.stringify(labels));
  let location = labels && labels.location;
  let projectId = labels && labels.project_id;
  let serviceName = labels && labels.service_name;

  // Validate data
  if (!location || !projectId || !serviceName) {
    console.error('The event does not contain one or more of the following parameters: region, project, or service name');
    throw new Error('Invalid event structure');
  }

  console.log(`Cloud Run service '${serviceName}' created in region '${location}' in project '${projectId}'. Applying tag to service...`);

  await callCreateTagBinding(projectId, location, serviceName);
});