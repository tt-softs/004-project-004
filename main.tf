provider "google" {
  credentials = "${file(var.gloud_creds_file)}"
  project     = "${var.project_name}"
  region      = "${var.region}"
}

provider "google-beta" {
  version     = "~> 2.7.0"
  credentials = "${file(var.gloud_creds_file)}"
  project     = var.project
  region      = var.region
}

terraform {
  required_version = ">= 0.12"
}

# ------------------------------------------------------------------------------
# CREATE A RANDOM SUFFIX AND PREPARE RESOURCE NAMES
# ------------------------------------------------------------------------------

locals {
  # If name_override is specified, use that - otherwise use the name_prefix with a random string
  instance_name        = var.name_override == null ? format("%s-%s", var.name_prefix, random_id.name.hex) : var.name_override
  private_network_name = "private-network-${var.cluster_name}"
  private_ip_name      = "private-ip-${var.cluster_name}"
}

# ------------------------------------------------------------------------------
# CREATE COMPUTE NETWORKS
# ------------------------------------------------------------------------------

# Simple network, auto-creates subnetworks
resource "google_compute_network" "private_network" {
  provider = "google-beta"
  name     = local.private_network_name
}

# Reserve global internal address range for the peering
resource "google_compute_global_address" "private_ip_address" {
  provider      = "google-beta"
  name          = local.private_ip_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private_network.self_link
}

# Establish VPC network peering connection using the reserved address range
resource "google_service_networking_connection" "private_vpc_connection" {
  provider                = "google-beta"
  network                 = google_compute_network.private_network.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# ------------------------------------------------------------------------------
# CREATE DATABASE INSTANCE WITH PRIVATE IP
# ------------------------------------------------------------------------------

module "postgres" {
  source = "./modules/cloud-sql"

  project = var.project
  region  = var.region
  name    = local.instance_name
  db_name = var.db_name

  engine       = var.postgres_version
  machine_type = var.machine_type

  master_user_password = "${random_id.password_database.hex}"

  master_user_name = var.master_user_name
  master_user_host = "%"

  # Pass the private network link to the module
  private_network = google_compute_network.private_network.self_link
  dependencies    = [google_service_networking_connection.private_vpc_connection.network]

  custom_labels = {
    test-id = "postgres-private-ip-example"
  }
}

resource "google_container_cluster" "primary" {
  name        = "${var.cluster_name}"
  project     = "${var.project_name}"
  description = "Demo GKE Cluster"
  # location    = "${var.region}-a"
  location = "${var.region_kuber}"
  # location    = "us-central1-a"
  # "${var.region}"
  min_master_version = "${var.kubernetes_ver}"
  network            = "${google_compute_network.private_network.self_link}"

  remove_default_node_pool = true
  initial_node_count       = 1

  master_auth {
    username = "${random_id.username.hex}"
    password = "${random_id.password.hex}"
  }
  ip_allocation_policy {
    use_ip_aliases = true
  }
  depends_on = ["google_service_networking_connection.private_vpc_connection"]
}

resource "google_container_node_pool" "primary" {
  name    = "${var.cluster_name}-node-pool"
  project = "${var.project_name}"
  # location = "${var.region}-a"
  location = "${var.region_kuber}"
  # location = "us-central1-a"
  # "${var.region}"
  cluster    = "${google_container_cluster.primary.name}"
  node_count = "${var.nodes_in_kuber}"

  node_config {
    preemptible  = true
    machine_type = "${var.machine_type_cluster}"

    metadata = {
      disable-legacy-endpoints = "true"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }
}

resource "google_compute_firewall" "default_ssh_http_https" {
  name    = "${var.cluster_name}-firewall"
  network = "${google_compute_network.private_network.name}"

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  cluster_ca_certificate = "${base64decode(google_container_cluster.primary.master_auth.0.cluster_ca_certificate)}"
  username               = "${random_id.username.hex}"
  password               = "${random_id.password.hex}"
}

data "template_file" "kubeconfig" {
  template = file("templates/kubeconfig-template.yaml")

  vars = {
    cluster_name    = google_container_cluster.primary.name
    user_name       = google_container_cluster.primary.master_auth[0].username
    user_password   = google_container_cluster.primary.master_auth[0].password
    endpoint        = google_container_cluster.primary.endpoint
    cluster_ca      = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
    client_cert     = google_container_cluster.primary.master_auth[0].client_certificate
    client_cert_key = google_container_cluster.primary.master_auth[0].client_key
  }
}

data "template_file" "spinnaker_chart" {
  template = file("templates/spinnaker-chart-template.yaml")

  vars = {
    google_project_name      = "${var.project_name}"
    google_spin_bucket_name  = "${google_storage_bucket.spinnaker-store.name}"
    google_subscription_name = "${google_pubsub_subscription.spinnaker_pubsub_subscription.name}"
    google_spin_sa_key       = "${base64decode(google_service_account_key.spinnaker-store-sa-key.private_key)}"
  }
}

data "template_file" "template_pipeline_spin_cfgmanapp" {
  template = file("templates/template_pipeline_spin_cfgmanapp.json")

  vars = {
    google_project_name = "${var.project_name}"
  }
}

data "template_file" "template_pipeline_spin_frontendapp" {
  template = file("templates/template_pipeline_spin_frontendapp.json")

  vars = {
    google_project_name = "${var.project_name}"
  }
}

data "template_file" "template_pipeline_spin_logicapp" {
  template = file("templates/template_pipeline_spin_logicapp.json")

  vars = {
    google_project_name = "${var.project_name}"
  }
}


data "template_file" "template_pipeline_spin_queryapp" {
  template = file("templates/template_pipeline_spin_queryapp.json")

  vars = {
    google_project_name = "${var.project_name}"
  }
}

data "template_file" "spinnaker_install_sh" {
  template = file("templates/create-spin-kub-file.sh-template")

  vars = {
    cluster_name = "${var.cluster_name}"
  }
}

resource "local_file" "template_pipeline_spin_queryapp" {
  content  = data.template_file.template_pipeline_spin_queryapp.rendered
  filename = "pipeline_spin_queryapp.json"
}

resource "local_file" "template_pipeline_spin_logicapp" {
  content  = data.template_file.template_pipeline_spin_logicapp.rendered
  filename = "pipeline_spin_logicapp.json"
}

resource "local_file" "template_pipeline_spin_frontendapp" {
  content  = data.template_file.template_pipeline_spin_frontendapp.rendered
  filename = "pipeline_spin_frontendapp.json"
}


resource "local_file" "template_pipeline_spin_cfgmanapp" {
  content  = data.template_file.template_pipeline_spin_cfgmanapp.rendered
  filename = "pipeline_spin_confmanapp.json"
}


resource "local_file" "kubeconfig" {
  content  = data.template_file.kubeconfig.rendered
  filename = "kubeconfig"
}

resource "local_file" "spinnaker_chart" {
  content  = data.template_file.spinnaker_chart.rendered
  filename = "spinnaker-chart.yaml"
}

resource "local_file" "spinnaker_install_sh" {
  content  = data.template_file.spinnaker_install_sh.rendered
  filename = "create-spin-kub-file.sh"
}


resource "google_service_account" "spinnaker-store-sa" {
  account_id   = "spinnaker-store-sa-id"
  display_name = "Spinnaker-store-sa"
  # depends_on = ["google_storage_bucket.spinnaker-store"]
}
resource "google_service_account_key" "spinnaker-store-sa-key" {
  service_account_id = "${google_service_account.spinnaker-store-sa.name}"
  public_key_type    = "TYPE_X509_PEM_FILE"
}
resource "google_storage_bucket" "spinnaker-store" {
  name          = "${var.project_name}-spinnaker-conf"
  location      = "EU"
  force_destroy = true
  //  lifecycle {
  //    prevent_destroy = true
  //  }
}

resource "google_storage_bucket_iam_binding" "spinnaker-bucket-iam" {
  bucket = "${google_storage_bucket.spinnaker-store.name}"
  role   = "roles/storage.admin"

  members = [
    "serviceAccount:${google_service_account.spinnaker-store-sa.email}",
  ]
}

resource "google_cloudbuild_trigger" "logicapp-trigger" {
  trigger_template {
    branch_name = "master"
    repo_name   = "github_kv-053-devops_logicapp"
  }
  description = "Trigger Git repository github_kv-053-devops_logicapp"
  filename    = "cloudbuild.yaml"
}

resource "google_cloudbuild_trigger" "frontendapp-trigger" {
  trigger_template {
    branch_name = "master"
    repo_name   = "github_kv-053-devops_frontendapp"
  }
  description = "Trigger Git repository github_kv-053-devops_frontendapp"
  filename    = "cloudbuild.yaml"
}

resource "google_cloudbuild_trigger" "frontendapp-queryapp" {
  trigger_template {
    branch_name = "master"
    repo_name   = "github_kv-053-devops_queryapp"
  }
  description = "Trigger Git repository github_kv-053-devops_queryapp"
  filename    = "cloudbuild.yaml"
}

resource "google_cloudbuild_trigger" "frontendapp-cfgmanapp" {
  trigger_template {
    branch_name = "master"
    repo_name   = "github_kv-053-devops_cfgmanapp"
  }
  description = "Trigger Git repository github_kv-053-devops_cfgmanapp"
  filename    = "cloudbuild.yaml"
}


resource "google_pubsub_subscription" "spinnaker_pubsub_subscription" {
  name  = "spinnaker-subscription"
  topic = "projects/${var.project_name}/topics/cloud-builds"

  message_retention_duration = "604800s"
  ack_deadline_seconds       = 20
  expiration_policy {
    ttl = "2592000s"
  }

}

resource "google_pubsub_subscription_iam_binding" "spinnaker_pubsub_iam_read" {
  subscription = "${google_pubsub_subscription.spinnaker_pubsub_subscription.name}"
  role         = "roles/pubsub.subscriber"
  members = [
    "serviceAccount:${google_service_account.spinnaker-store-sa.email}",
  ]
}

resource "kubernetes_namespace" "prod" {
  metadata {
    name = "prod"
  }
  depends_on = ["google_container_node_pool.primary"]
}

resource "kubernetes_namespace" "dev" {
  metadata {
    name = "dev"
  }
  depends_on = ["google_container_node_pool.primary"]
}

resource "kubernetes_namespace" "spinnaker" {
  metadata {
    name = "spinnaker"
  }
  depends_on = ["google_container_node_pool.primary"]
}

resource "kubernetes_namespace" "istio-system" {
  metadata {
    name = "istio-system"
  }
  depends_on = ["google_container_node_pool.primary"]
}


resource "kubernetes_config_map" "logicapp-env-conf" {
  metadata {
    name      = "logicapp-env-vars"
    namespace = "dev"
  }

  data = {
    logicapp-app-query-url = "${var.logicapp_conf_query_url}"
  }
  depends_on = ["kubernetes_namespace.dev"]
}

resource "kubernetes_config_map" "frontendapp-env-conf" {
  metadata {
    name      = "frontendapp-env-vars"
    namespace = "dev"
  }

  data = {
    app_query_url         = "${var.frontendapp_app_query_url}"
    app_settings_url      = "${var.frontendapp_app_settings_url}"
    app_settings_save_url = "${var.frontendapp_app_settings_save_url}"
  }
  depends_on = ["kubernetes_namespace.dev"]
}

resource "kubernetes_config_map" "queryapp-env-conf" {
  metadata {
    name      = "queryapp-env-vars"
    namespace = "dev"
  }

  data = {
    config_api_url = "${var.queryapp_config_api_url}"
  }
  depends_on = ["kubernetes_namespace.dev"]
}
resource "kubernetes_secret" "credentials_db" {
  metadata {
    name      = "credentials-db"
    namespace = "dev"
  }

  data = {
    db_user_name = "${var.master_user_name}"
    db_user_pass = "${random_id.password_database.hex}"
    db_name      = module.postgres.db_name
    db_address   = module.postgres.master_private_ip_address
  }
  depends_on = ["kubernetes_namespace.dev"]
}

resource "null_resource" "configure_tiller_spinnaker" {
  provisioner "local-exec" {
    command = <<LOCAL_EXEC
bash create-spin-kub-file.sh
kubectl config use-context ${var.cluster_name} --kubeconfig=${local_file.kubeconfig.filename}
kubectl apply -f create-helm-service-account.yml --kubeconfig=${local_file.kubeconfig.filename}
helm init --service-account helm --upgrade --wait --kubeconfig=${local_file.kubeconfig.filename}
helm install -n spin stable/spinnaker --namespace spinnaker -f ${local_file.spinnaker_chart.filename} --timeout 1200 --version 1.8.1 --wait --kubeconfig=${local_file.kubeconfig.filename}
bash forward_spin_gate.sh
LOCAL_EXEC
  }
  depends_on = ["google_container_node_pool.primary", "local_file.kubeconfig", "kubernetes_namespace.spinnaker", "local_file.spinnaker_chart", "local_file.spinnaker_chart", "google_storage_bucket_iam_binding.spinnaker-bucket-iam", "google_pubsub_subscription_iam_binding.spinnaker_pubsub_iam_read", "local_file.spinnaker_install_sh"]
}

# kubectl apply -f istio-files/helm-service-account.yaml
# helm init --service-account tiller

resource "null_resource" "configure_istio" {
  provisioner "local-exec" {
    command = <<LOCAL_EXEC
helm install istio-files/istio-init --name istio-init --namespace istio-system  --kubeconfig=${local_file.kubeconfig.filename}
sleep 90
kubectl get crds  --kubeconfig=${local_file.kubeconfig.filename} | grep 'istio.io' | wc -l
helm install istio-files/istio --name istio --namespace istio-system --values istio-files/istio/values.yaml --timeout 600 --wait  --kubeconfig=${local_file.kubeconfig.filename}
kubectl label namespace dev istio-injection=enabled --kubeconfig=${local_file.kubeconfig.filename}
kubectl get svc -n istio-system --kubeconfig=${local_file.kubeconfig.filename}
kubectl get pods -n istio-system --kubeconfig=${local_file.kubeconfig.filename}
LOCAL_EXEC
  }
  depends_on = ["null_resource.configure_tiller_spinnaker"]
}
