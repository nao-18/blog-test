# dialog Terraform

This Terraform creates the infrastructure requested in `dialog.md`:

- External HTTP Load Balancer
- GCE app self-managed instance group attached to the load balancer
- Standalone GCE instances for `db` and `monitor`
- Containerized HTTP function deployed as a Cloud Run service
- Artifact Registry Docker repository for function images

All Compute Engine instances use the official Rocky Linux 10 image family
(`rocky-linux-cloud/rocky-linux-10`). The HTTP function uses Functions Framework
and is packaged by `function/Dockerfile`. Terraform deploys that image with
`google_cloud_run_v2_service`; it no longer uploads a source ZIP to Cloud
Storage.

## Usage

```sh
terraform init
terraform apply \
  -target='google_project_service.required' \
  -target='google_artifact_registry_repository.function' \
  -var="project_id=YOUR_PROJECT_ID"
```

Authenticate Docker, then build and push the function image:

```sh
gcloud auth configure-docker REGION-docker.pkg.dev

docker buildx build \
  --platform=linux/amd64 \
  --push \
  --tag=REGION-docker.pkg.dev/YOUR_PROJECT_ID/NAME_PREFIX-functions/gemini-enterprise-hook:v1 \
  function
```

Deploy the complete infrastructure with the same immutable image tag:

```sh
terraform plan \
  -var="project_id=YOUR_PROJECT_ID" \
  -var="function_image_tag=v1"
terraform apply \
  -var="project_id=YOUR_PROJECT_ID" \
  -var="function_image_tag=v1"
```

Replace `REGION` and `NAME_PREFIX` with the configured `region` and
`name_prefix` values. Use a new `function_image_tag` for each release so that
Terraform creates a new Cloud Run revision.

The project must have billing enabled. The Service Usage API must already be enabled before Terraform can manage other project services.

VMs receive dedicated regional static external IPv4 addresses. Inbound access remains limited by
the configured firewall rules. To enable SSH, pass trusted CIDR ranges through
`allowed_ssh_ranges`.
