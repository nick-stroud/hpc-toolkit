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

locals {
  # This label allows for billing report tracking based on module.
  labels = merge(var.labels, { ghpc_module = "gke-persistent-volume" })
}

locals {
  location             = split("/", var.filestore_id)[3]
  filestore_name       = split("/", var.filestore_id)[5]
  filestore_share_name = trimprefix(var.network_storage.remote_mount, "/")

  pv_name  = "${local.filestore_name}-pv"
  pvc_name = "${local.filestore_name}-pvc"

  filestore_pv_contents = templatefile(
    "${path.module}/templates/filestore-pv.yaml.tftpl",
    {
      pv_name        = local.pv_name
      capacity       = "${var.capacity_gb}Gi"
      location       = local.location
      filestore_name = local.filestore_name
      share_name     = local.filestore_share_name
      ip_address     = var.network_storage.server_ip
      labels         = local.labels
    }
  )

  filestore_pvc_contents = templatefile(
    "${path.module}/templates/filestore-pvc.yaml.tftpl",
    {
      pv_name  = local.pv_name
      capacity = "${var.capacity_gb}Gi"
      pvc_name = local.pvc_name
      labels   = local.labels
    }
  )

  cluster_name     = split("/", var.cluster_id)[5]
  cluster_location = split("/", var.cluster_id)[3]
}

resource "local_file" "debug_file" {
  content  = <<-EOF
    ${local.filestore_pv_contents}
    ${local.filestore_pvc_contents}
    EOF
  filename = "${path.root}/pv-pvc-debug-file-${local.filestore_name}.yaml"
}

data "google_container_cluster" "gke_cluster" {
  name     = local.cluster_name
  location = local.cluster_location
}

data "google_client_config" "default" {}

provider "kubectl" {
  host                   = "https://${data.google_container_cluster.gke_cluster.endpoint}"
  cluster_ca_certificate = base64decode(data.google_container_cluster.gke_cluster.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
  load_config_file       = false
}

resource "kubectl_manifest" "filestore_pv" {
  yaml_body = (
    var.network_storage.fs_type == "gcsfuse" ? 
    local.gcs_pv_contents : 
    local.filestore_pv_contents
  )
  lifecycle {
    precondition {
      condition     = contains(["gcsfuse", "nfs"], var.network_storage.fs_type)
      error_message = "Only fs_type gcsfuse or nfs are supported."
    }
    precondition {
      condition     = var.network_storage.fs_type == "gcsfuse" == (var.filestore_id == null)
      error_message = "filestore_id should not be provided when using a gcs bucket."
    }
    precondition {
      condition     = var.service_account_email != null ? var.network_storage.fs_type == "gcsfuse" : true
      error_message = "Service account can only be provided when used with a GCS bucket."
    }
  }
}

resource "kubectl_manifest" "filestore_pvc" {
  yaml_body  = local.filestore_pvc_contents
  depends_on = [kubectl_manifest.filestore_pv]
}
