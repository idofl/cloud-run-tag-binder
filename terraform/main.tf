/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.77.0"
    }
  }

  provider_meta "google" {
    module_name = "cloud-solutions/public-cloud-run-with-drs-deploy-v1.0"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google" {
  alias = "with_billing_project"
  project = var.project_id
  region  = var.region
  # override user project to enable calling APIs over folders and org
  # that require a billable project
  user_project_override = true
  billing_project = var.project_id
}

data "google_project" "project" {
}

locals {
  app_service_account_name = "cloud-run-tag-binder"
  trigger_service_account_name = "cloud-run-notifier"

  sink_name = "cloud-run-create-service-sink"
  sink_topic = "cloud-run-logs"
  sink_destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${local.sink_topic}"

  tag_name = "AllowPublicAccess"
  tag_value = "True"

  tag_role_name = "runTagBinder"
  cloud_build_bucket = "${var.project_id}_cloudbuild"

  org_id = "organizations/${var.organization_id}"
  folder_id = "folders/${var.cloud_run_root_folder}"
  project_number = data.google_project.project.number

  run_service_name = "cloud-run-service-tag-binder"

  services = [
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "logging.googleapis.com",
    "cloudbuild.googleapis.com",
    "pubsub.googleapis.com",
    "orgpolicy.googleapis.com",
    "eventarc.googleapis.com",
  ]

  log_filter = <<EOT
  LOG_ID("cloudaudit.googleapis.com/activity") AND
  protoPayload.methodName="google.cloud.run.v1.Services.CreateService" AND
  resource.type="cloud_run_revision"
  EOT
}

resource "google_project_service" "services" {
  for_each = toset(local.services)
  service = each.value
  disable_on_destroy = false
}

resource "google_service_account" "app_service_account" {
  account_id   = local.app_service_account_name
  display_name = "Service account with permissions to bind tag value to Cloud Run services"
}

resource "google_service_account" "trigger_service_account" {
  account_id   = local.trigger_service_account_name
  display_name = "Service account with permissions to invoke the Cloud Run service"
}

resource "google_tags_tag_key" "allow_public_access" {
  parent = local.org_id
  short_name = local.tag_name
}

resource "google_tags_tag_value" "allow_public_access_value" {
  parent = "tagKeys/${google_tags_tag_key.allow_public_access.name}"
  short_name = local.tag_value
}

resource "google_org_policy_policy" "drs_org_policy" {
  provider = google.with_billing_project
  name     = "${local.folder_id != "" ?local.folder_id : local.org_id}/policies/iam.allowedPolicyMemberDomains"
  parent   = (local.folder_id != "" ? local.folder_id : 
              local.org_id)

  spec {
    inherit_from_parent = true
    rules {
      allow_all = "TRUE"
      condition {
        expression = "resource.matchTag('${google_tags_tag_key.allow_public_access.namespaced_name}', '${google_tags_tag_value.allow_public_access_value.short_name}')"
        title = "Allow DRS if tag exists"
      }
    }
  }
}

resource "google_organization_iam_custom_role" "cloud_run_tag_binder" {
  role_id     = local.tag_role_name
  title       = "Cloud Run Tag Binder"
  description = "Have access to create tag bindings for cloud run services"
  permissions = ["run.services.createTagBinding"]
  org_id      = var.organization_id
}

resource "google_tags_tag_value_iam_binding" "tag_value_iam" {
  tag_value = google_tags_tag_value.allow_public_access_value.name
  role = "roles/resourcemanager.tagUser"
  members = [
    google_service_account.app_service_account.member
  ]
}

resource "google_folder_iam_binding" "tab_binder_folder_root_iam" {
  folder = local.folder_id
  role = "${local.org_id}/roles/${local.tag_role_name}"

  members = [
    google_service_account.app_service_account.member,
  ]

  count = "${local.folder_id != "" ? 1 : 0}"
}

resource "google_organization_iam_binding" "tab_binder_org_root_iam" {
  org_id = var.organization_id
  role = "${local.org_id}/roles/${local.tag_role_name}"

  members = [
    google_service_account.app_service_account.member,
  ]

  count = "${local.folder_id == "" ? 1 : 0}"
}

resource "google_service_account_iam_binding" "pubsub_act_as_trigger_iam" {
  service_account_id = google_service_account.trigger_service_account.name
  role = "roles/iam.serviceAccountTokenCreator"

  members = [
    "serviceAccount:service-${local.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com",
  ]
}

resource "google_pubsub_topic" "sink_topic" {
  name = local.sink_topic
}

resource "google_logging_folder_sink" "run_logs_sink_root_folder" {
  name = local.sink_name
  description = "Cloud Run Create Service sink"
  include_children = true
  folder = local.folder_id
  destination = local.sink_destination
  filter = local.log_filter

  count = "${local.folder_id != "" ? 1 : 0}"
}

resource "google_logging_organization_sink" "run_logs_sink_root_org" {
  name   = local.sink_name
  description = "Cloud Run Create Service sink"
  include_children = true
  org_id = var.organization_id
  destination = local.sink_destination
  filter = local.log_filter

  count = "${local.folder_id == "" ? 1 : 0}"
}

resource "google_pubsub_topic_iam_binding" "sink_topic_iam" {
  topic = google_pubsub_topic.sink_topic.name
  role = "roles/pubsub.publisher"
  members = [
    (local.folder_id != "" ? google_logging_folder_sink.run_logs_sink_root_folder[0].writer_identity : 
      google_logging_organization_sink.run_logs_sink_root_org[0].writer_identity)
  ]
}

resource "google_storage_bucket" "build_bucket" {
  name          = local.cloud_build_bucket
  location      = var.region
  uniform_bucket_level_access = true
  force_destroy = true
}

output "tag_value" {
  value = google_tags_tag_value.allow_public_access_value.id
}

output "app_service_account" {
  value = google_service_account.app_service_account.email
}

output "trigger_service_account" {
  value = google_service_account.trigger_service_account.email
}

output "sink_topic" {
  value = local.sink_topic
}
