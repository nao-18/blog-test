# dialog Terraform

This Terraform creates the infrastructure requested in `dialog.md`:

- External HTTP Load Balancer
- GCE app self-managed instance group attached to the load balancer
- Standalone private GCE instances for `db` and `monitor`
- Cloud Functions Gen2 HTTP function, including source archive bucket and required APIs

## Usage

```sh
terraform init
terraform plan -var="project_id=YOUR_PROJECT_ID"
terraform apply -var="project_id=YOUR_PROJECT_ID"
```

The project must have billing enabled. The Service Usage API must already be enabled before Terraform can manage other project services.

VMs are created without external IP addresses. To enable SSH, pass `allowed_ssh_ranges`; otherwise use IAP, a bastion, or your existing private access path.
