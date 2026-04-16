# GCP CI/CD Pipeline — Python Web App on GKE Autopilot

**Author:** Arun Ponugoti  
**Project ID:** `project-69f6f6fe-42ac-4d0e-8cd`  
**Region:** `us-central1`

---

## Table of Contents

1. [What Is This Project?](#1-what-is-this-project)
2. [Tech Stack](#2-tech-stack)
3. [Directory Structure](#3-directory-structure)
4. [Architecture — How Everything Connects](#4-architecture--how-everything-connects)
5. [The Application](#5-the-application)
6. [Infrastructure — Terraform](#6-infrastructure--terraform)
7. [Kubernetes Manifests](#7-kubernetes-manifests)
8. [CI/CD Pipeline — GitHub Actions](#8-cicd-pipeline--github-actions)
9. [Cloud Deploy — Delivery Pipeline](#9-cloud-deploy--delivery-pipeline)
10. [IAM Permissions — Who Can Do What](#10-iam-permissions--who-can-do-what)
11. [One-Time Setup Guide](#11-one-time-setup-guide)
12. [How to Trigger a Deployment](#12-how-to-trigger-a-deployment)
13. [Troubleshooting Log — Issues Debugged and Resolved](#13-troubleshooting-log--issues-debugged-and-resolved)

---

## 1. What Is This Project?

This project demonstrates a **production-style CI/CD pipeline on Google Cloud Platform (GCP)**. When you click one button in GitHub, the following happens automatically:

1. A Docker image of a Python web app is built
2. The image is pushed to Google's private container registry
3. The app is deployed to a Kubernetes cluster in a **staging environment**
4. A human manually reviews and approves promotion to **production**

The entire pipeline uses **no passwords or keys** — authentication between GitHub and GCP is done securely using short-lived OIDC tokens (Workload Identity Federation).

### What problem does this solve?

Without a CI/CD pipeline, a developer would manually:
- Build the Docker image on their laptop
- Push it to a registry
- Run `kubectl apply` to deploy

This is error-prone, inconsistent, and doesn't scale. This project automates everything from a single click in GitHub.

---

## 2. Tech Stack

| Tool | Purpose |
|------|---------|
| **Python + Flask** | The web application |
| **Docker** | Packages the app into a portable container image |
| **Terraform** | Creates all GCP infrastructure (cluster, registry, service accounts) |
| **GitHub Actions** | CI/CD trigger — builds image and creates a deployment release |
| **Google Artifact Registry** | Stores Docker images privately |
| **Google Cloud Deploy** | Manages progressive rollout: staging → production |
| **Google Kubernetes Engine (GKE) Autopilot** | Runs the containers; auto-manages node infrastructure |
| **Kustomize** | Customizes Kubernetes manifests per environment without duplication |
| **Skaffold** | Tells Cloud Deploy how to render and apply Kubernetes manifests |
| **Workload Identity Federation (WIF)** | Lets GitHub Actions authenticate to GCP without storing any secret keys |

---

## 3. Directory Structure

```
gcp-cicd-project/
│
├── .github/
│   └── workflows/
│       └── cicd.yml              # GitHub Actions pipeline (the main trigger)
│
├── app/
│   ├── app.py                    # Python Flask web application
│   ├── requirements.txt          # Python dependencies
│   └── Dockerfile                # Instructions to build the Docker image
│
├── k8s/
│   ├── skaffold.yaml             # Tells Cloud Deploy which k8s profiles to use
│   ├── cloudbuild.yaml           # (Reference only) Original Cloud Build config
│   ├── clouddeploy.yaml          # Defines the delivery pipeline and targets
│   │
│   ├── base/                     # Shared Kubernetes config (used by both environments)
│   │   ├── deployment.yaml       # How to run the app (replicas, image, env vars)
│   │   ├── service.yaml          # How to expose the app (LoadBalancer on port 80)
│   │   └── kustomization.yaml    # Lists which files are in base
│   │
│   └── overlays/
│       ├── staging/
│       │   └── kustomization.yaml  # Overrides: sets namespace=staging, ENVIRONMENT=STAGING
│       └── production/
│           └── kustomization.yaml  # Overrides: namespace=production, ENVIRONMENT=PRODUCTION
│
└── terraform/
    ├── main.tf                   # Creates GCP infrastructure
    ├── variables.tf              # Input variables (project ID, region, app name)
    └── provider.tf               # GCP provider configuration
```

---

## 4. Architecture — How Everything Connects

### Full Pipeline Flow

```
Developer clicks "Run workflow" in GitHub
             │
             ▼
┌─────────────────────────┐
│     GitHub Actions      │  (.github/workflows/cicd.yml)
│                         │
│  1. Checkout code       │
│  2. Auth to GCP via WIF │◄── No keys! Uses OIDC token
│  3. Build Docker image  │
│  4. Push image          │──► Artifact Registry
│  5. Create CD release   │──► Cloud Deploy
└─────────────────────────┘
             │
             ▼
┌─────────────────────────┐
│     Cloud Deploy        │  (python-app-pipeline)
│                         │
│  Render manifests       │◄── skaffold.yaml + kustomize overlays
│  (via Cloud Build)      │
│                         │
│  Auto-deploy ──────────►│──► GKE staging namespace
│                         │
│  Wait for approval      │
│  Manual promote ───────►│──► GKE production namespace
└─────────────────────────┘
             │
             ▼
┌─────────────────────────┐
│   GKE Autopilot Cluster │  (python-web-app-cluster)
│                         │
│  staging namespace      │  ENVIRONMENT=STAGING
│  production namespace   │  ENVIRONMENT=PRODUCTION
│                         │
│  LoadBalancer Service   │──► Public IP → Browser
└─────────────────────────┘
```

### Authentication Flow (WIF — No Keys)

```
GitHub Actions Runner
       │
       │ generates OIDC token
       │ "I am repo arunponugoti1/gke-multi-env-project"
       ▼
GCP Workload Identity Pool (github-pool)
       │
       │ validates token against GitHub's OIDC endpoint
       │ checks: is this the right repo? (attribute.repository condition)
       ▼
Service Account (cicd-pipeline-sa)
       │ impersonated — gets temporary credentials (no permanent key)
       ▼
GCP APIs: Artifact Registry, Cloud Deploy, Cloud Build, GCS
```

### How Kustomize Works (DRY Config)

```
k8s/base/
  deployment.yaml  ← shared config (image placeholder, port 8080)
  service.yaml     ← LoadBalancer on port 80

        ┌──────────────────────────┐
        │                          │
        ▼                          ▼
k8s/overlays/staging/      k8s/overlays/production/
  namespace: staging          namespace: production
  ENVIRONMENT=STAGING         ENVIRONMENT=PRODUCTION

Result: same base, different env per deployment
```

---

## 5. The Application

**File:** `app/app.py`

```python
from flask import Flask
import os

app = Flask(__name__)
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'Local')

@app.route('/')
def hello():
    return f"<h1>Hello from GKE Autopilot!</h1><h2>Environment: {ENVIRONMENT}</h2>"
```

A simple Flask web app that reads the `ENVIRONMENT` environment variable and displays it. This variable is injected differently per environment by Kustomize:
- Staging cluster shows: **"Environment: STAGING"**
- Production cluster shows: **"Environment: PRODUCTION"**

**File:** `app/Dockerfile`

```dockerfile
FROM python:3.11-slim
RUN useradd -m appuser       # Security: run as non-root user
USER appuser
WORKDIR /home/appuser/app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
```

Key security practice: the app runs as `appuser`, not `root`. If the container is compromised, the attacker does not have root access to the container filesystem.

**File:** `app/requirements.txt`

```
flask
```

---

## 6. Infrastructure — Terraform

All GCP infrastructure is defined as code in the `terraform/` directory. Running `terraform apply` once creates everything needed before the pipeline can run.

**File:** `terraform/variables.tf`

| Variable | Value | Purpose |
|----------|-------|---------|
| `project_id` | `project-69f6f6fe-42ac-4d0e-8cd` | GCP project |
| `region` | `us-central1` | Where all resources live |
| `app_name` | `python-web-app` | Used to name all resources consistently |

**File:** `terraform/main.tf` — creates 4 groups of resources:

### 6.1 Enable GCP APIs

```hcl
resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",       # GKE
    "cloudbuild.googleapis.com",      # Cloud Build (used internally by Cloud Deploy)
    "artifactregistry.googleapis.com",# Artifact Registry
    "clouddeploy.googleapis.com",     # Cloud Deploy
  ])
}
```

GCP services are disabled by default for security. Terraform enables exactly what is needed.

### 6.2 Artifact Registry Repository

```hcl
resource "google_artifact_registry_repository" "docker_repo" {
  repository_id = "python-web-app-images"
  format        = "DOCKER"
  location      = "us-central1"
}
```

A private Docker registry hosted in GCP. All built images are stored here. Think of it like a private DockerHub inside your GCP project.

### 6.3 GKE Autopilot Cluster

```hcl
resource "google_container_cluster" "primary" {
  name             = "python-web-app-cluster"
  location         = "us-central1"
  enable_autopilot = true
}
```

**Autopilot mode** means GCP automatically manages nodes (virtual machines). You don't provision or pay for idle VMs — nodes are created on-demand when pods need to run and removed when they don't. No node management overhead.

### 6.4 CI/CD Service Account + Roles

```hcl
resource "google_service_account" "cicd_sa" {
  account_id = "cicd-pipeline-sa"
}

resource "google_project_iam_member" "cicd_roles" {
  for_each = toset([
    "roles/source.reader",            # Read source repos
    "roles/artifactregistry.writer",  # Push Docker images
    "roles/container.developer",      # Deploy to GKE
    "roles/clouddeploy.operator",     # Create Cloud Deploy releases
    "roles/iam.serviceAccountUser",   # Act as other SAs
  ])
}
```

This service account is the identity that GitHub Actions uses when it interacts with GCP.

---

## 7. Kubernetes Manifests

### Base Manifests

**File:** `k8s/base/deployment.yaml`

Defines how Kubernetes should run the application:
- `replicas: 1` — run 1 copy of the pod
- `image: python-web-app-image` — placeholder; Cloud Deploy substitutes the real image URI at deploy time
- `containerPort: 8080` — the app listens on port 8080
- `ENVIRONMENT: "Base"` — overridden by kustomize overlays

**File:** `k8s/base/service.yaml`

Exposes the app to the internet:
- `type: LoadBalancer` — GCP provisions a public IP address
- `port: 80` — users access via port 80 (standard HTTP)
- `targetPort: 8080` — traffic forwarded to the container's port 8080

### Kustomize Overlays

**File:** `k8s/overlays/staging/kustomization.yaml`

```yaml
namespace: staging           # Deploy into the 'staging' namespace
patches:
- patch: |-
    env:
    - name: ENVIRONMENT
      value: "STAGING"       # Override the base ENVIRONMENT value
```

**File:** `k8s/overlays/production/kustomization.yaml`

```yaml
namespace: production
patches:
- patch: |-
    env:
    - name: ENVIRONMENT
      value: "PRODUCTION"
```

Kustomize reads the base config and applies these patches on top. No copy-paste duplication — you only define what's different per environment.

### Skaffold Config

**File:** `k8s/skaffold.yaml`

```yaml
profiles:
- name: staging
  manifests:
    kustomize:
      paths:
      - overlays/staging     # Use staging kustomize overlay
- name: production
  manifests:
    kustomize:
      paths:
      - overlays/production
```

Skaffold is the glue between Cloud Deploy and Kustomize. Cloud Deploy calls Skaffold with a profile name (`staging` or `production`), and Skaffold knows which kustomize overlay to apply.

### Cloud Deploy Config

**File:** `k8s/clouddeploy.yaml`

```yaml
apiVersion: deploy.cloud.google.com/v1
kind: DeliveryPipeline
metadata:
  name: python-app-pipeline
serialPipeline:
  stages:
  - targetId: staging        # Stage 1: auto-deploy here
  - targetId: production     # Stage 2: requires human approval
---
kind: Target
metadata:
  name: staging
gke:
  cluster: projects/.../clusters/python-web-app-cluster
---
kind: Target
metadata:
  name: production
requireApproval: true         # Blocks promotion until manually approved
gke:
  cluster: projects/.../clusters/python-web-app-cluster
```

This file defines the delivery pipeline. Both environments deploy to the same GKE cluster but into different Kubernetes **namespaces** (`staging` and `production`), which provides logical isolation.

---

## 8. CI/CD Pipeline — GitHub Actions

**File:** `.github/workflows/cicd.yml`

### Trigger

```yaml
on:
  workflow_dispatch:    # Manual trigger only — click "Run workflow" in GitHub UI
```

The pipeline only runs when explicitly triggered. It does not auto-run on every commit (by design — gives control over when deployments happen).

### Permissions Block

```yaml
permissions:
  contents: read
  id-token: write      # CRITICAL: allows GitHub to generate OIDC token for WIF auth
```

`id-token: write` is required for Workload Identity Federation. Without it, GitHub cannot generate the OIDC token needed to authenticate to GCP.

### Pipeline Steps Explained

#### Step 1 — Checkout

```yaml
- uses: actions/checkout@v4
```

Downloads the repository code onto the GitHub Actions runner (a temporary Ubuntu VM).

#### Step 2 — Authenticate to GCP (WIF)

```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
    service_account: ${{ secrets.WIF_SERVICE_ACCOUNT }}
```

No password or key file. GitHub generates a signed JWT token proving "this is workflow running in `arunponugoti1/gke-multi-env-project`". GCP validates this token against its Workload Identity Pool and grants temporary credentials to act as `cicd-pipeline-sa`.

#### Step 3 — Set Up gcloud SDK

```yaml
- uses: google-github-actions/setup-gcloud@v2
```

Installs the `gcloud` CLI on the runner so subsequent steps can run gcloud commands.

#### Step 4 — Configure Docker

```yaml
- run: gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
```

Tells the local Docker daemon to use gcloud credentials when pushing to Artifact Registry. Without this, `docker push` would be rejected with 401 Unauthorized.

#### Step 5 — Build Docker Image

```yaml
- run: docker build -t us-central1-docker.pkg.dev/PROJECT_ID/python-web-app-images/python-web-app:SHA ./app
```

Builds the image from the `app/` directory. Tagged with the full Git commit SHA for traceability — you can always know exactly which commit is running in any environment.

#### Step 6 — Push Image

```yaml
- run: docker push us-central1-docker.pkg.dev/PROJECT_ID/python-web-app-images/python-web-app:SHA
```

Pushes the built image to Artifact Registry. The image is now available for GKE to pull.

#### Step 7 — Create Cloud Deploy Release

```yaml
- run: |
    SHORT_SHA=$(echo "$SHA" | cut -c1-7)
    gcloud deploy releases create "release-${SHORT_SHA}-${RUN_NUMBER}-${RUN_ATTEMPT}" \
      --delivery-pipeline=python-app-pipeline \
      --skaffold-file=skaffold.yaml \
      --source=k8s \
      --images=python-web-app-image=FULL_IMAGE_URI:SHA
```

This is the key step:
- `--source=k8s` — uploads the entire `k8s/` folder to a GCS bucket
- Cloud Deploy internally runs a Cloud Build job to **render** the manifests using Skaffold + Kustomize
- The rendered manifests are stored in GCS
- Cloud Deploy automatically triggers a rollout to **staging**
- The release name uses `run_number` + `run_attempt` to guarantee uniqueness even if you re-run the same workflow

---

## 9. Cloud Deploy — Delivery Pipeline

Once a release is created, Cloud Deploy manages the rest:

```
Release created
      │
      ▼
┌─────────────────┐
│ RENDER phase    │  Cloud Deploy runs Cloud Build internally
│                 │  Skaffold renders kustomize overlays
│                 │  Stores rendered manifests in GCS
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ STAGING rollout │  Automatic
│                 │  kubectl apply to staging namespace
│                 │  Waits for pods to be Ready
└────────┬────────┘
         │
         │  ◄── Human goes to Cloud Deploy console
         │  ◄── Clicks "Promote" → "Approve"
         ▼
┌─────────────────┐
│ PRODUCTION      │  Manual approval required
│ rollout         │  kubectl apply to production namespace
└─────────────────┘
```

### To approve production promotion:

1. Go to **GCP Console → Cloud Deploy → Delivery Pipelines → python-app-pipeline**
2. Find the release with status "Pending approval"
3. Click **Promote** → **Approve**
4. The app rolls out to production

---

## 10. IAM Permissions — Who Can Do What

Understanding IAM is critical. Here is every permission granted, why it exists, and what breaks without it.

### Service Account: `cicd-pipeline-sa` (used by GitHub Actions)

| Role | Why Needed |
|------|-----------|
| `roles/artifactregistry.writer` | Push Docker images to Artifact Registry |
| `roles/clouddeploy.operator` | Create releases in Cloud Deploy |
| `roles/container.developer` | Deploy workloads to GKE |
| `roles/storage.admin` | Upload release source to GCS bucket |
| `roles/iam.serviceAccountUser` | Act as other service accounts |
| `roles/source.reader` | Read source repositories |

### Service Account: `PROJECT_NUMBER-compute@developer.gserviceaccount.com` (Compute Default SA — used by Cloud Build and GKE nodes)

| Role | Why Needed |
|------|-----------|
| `roles/logging.logWriter` | Write Cloud Build logs to Cloud Logging |
| `roles/container.developer` | Cloud Deploy deploy jobs can apply to GKE |
| `roles/storage.admin` | Cloud Build render jobs write rendered manifests to GCS |
| `roles/storage.objectViewer` | Read source archives from GCS |
| `roles/artifactregistry.reader` | GKE nodes pull Docker images from Artifact Registry |

### Service Account: `service-PROJECT_NUMBER@gcp-sa-clouddeploy.iam.gserviceaccount.com` (Cloud Deploy System SA)

| Role | Why Needed |
|------|-----------|
| `roles/clouddeploy.jobRunner` | Run deploy jobs |
| `roles/container.developer` | Apply Kubernetes manifests |
| `roles/iam.serviceAccountUser` on Compute SA | Trigger Cloud Build using the Compute SA |

### Workload Identity Federation

| Resource | Purpose |
|----------|---------|
| **WIF Pool:** `github-pool` | Trust store for GitHub OIDC tokens |
| **WIF Provider:** `github-provider` | Validates tokens from `https://token.actions.githubusercontent.com` |
| **Attribute condition:** `assertion.repository=='arunponugoti1/gke-multi-env-project'` | Only THIS specific repo can authenticate — prevents other repos from impersonating the SA |
| **IAM binding:** `roles/iam.workloadIdentityUser` on `cicd-pipeline-sa` | Allows the WIF principal to impersonate the SA |

---

## 11. One-Time Setup Guide

These steps are done once to set up the infrastructure. After this, only `git push` + `Run workflow` is needed.

### Step 1 — Prerequisites

```bash
# Install tools
gcloud CLI, terraform, kubectl

# Authenticate gcloud
gcloud auth login
gcloud config set project project-69f6f6fe-42ac-4d0e-8cd
```

### Step 2 — Provision Infrastructure with Terraform

```bash
cd terraform/
terraform init
terraform apply
```

This creates:
- GKE Autopilot cluster (`python-web-app-cluster`)
- Artifact Registry repo (`python-web-app-images`)
- Service Account (`cicd-pipeline-sa`) with roles
- Enables all required GCP APIs

### Step 3 — Set Up Workload Identity Federation

```bash
PROJECT_ID="project-69f6f6fe-42ac-4d0e-8cd"
PROJECT_NUMBER="85539739058"
SA_EMAIL="cicd-pipeline-sa@${PROJECT_ID}.iam.gserviceaccount.com"
GITHUB_ORG="arunponugoti1"
GITHUB_REPO="gke-multi-env-project"

# Create WIF pool
gcloud iam workload-identity-pools create "github-pool" \
  --project=$PROJECT_ID \
  --location="global" \
  --display-name="GitHub Actions Pool"

# Create OIDC provider
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project=$PROJECT_ID \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor" \
  --attribute-condition="assertion.repository=='${GITHUB_ORG}/${GITHUB_REPO}'"

# Allow only your repo to impersonate the SA
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --project=$PROJECT_ID \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}"
```

### Step 4 — Grant Additional IAM Permissions (post-Terraform)

```bash
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
CLOUDDEPLOY_SA="service-${PROJECT_NUMBER}@gcp-sa-clouddeploy.iam.gserviceaccount.com"

# Compute SA permissions (Cloud Build + GKE node image pull)
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${COMPUTE_SA}" --role="roles/logging.logWriter"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${COMPUTE_SA}" --role="roles/container.developer"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${COMPUTE_SA}" --role="roles/storage.admin"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${COMPUTE_SA}" --role="roles/artifactregistry.reader"

# Cloud Deploy system SA permissions
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${CLOUDDEPLOY_SA}" --role="roles/clouddeploy.jobRunner"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${CLOUDDEPLOY_SA}" --role="roles/container.developer"
gcloud iam service-accounts add-iam-policy-binding ${COMPUTE_SA} \
  --project=$PROJECT_ID \
  --role="roles/iam.serviceAccountUser" \
  --member="serviceAccount:${CLOUDDEPLOY_SA}"

# cicd-pipeline-sa additional permission
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.admin"
```

### Step 5 — Register Cloud Deploy Pipeline

```bash
cd k8s/
gcloud deploy apply \
  --file=clouddeploy.yaml \
  --region=us-central1 \
  --project=project-69f6f6fe-42ac-4d0e-8cd
```

This registers the `python-app-pipeline` and the `staging` and `production` targets in Cloud Deploy. **This must be done before triggering the GitHub Actions workflow.**

### Step 6 — Create GKE Namespaces

```bash
gcloud container clusters get-credentials python-web-app-cluster \
  --region=us-central1 \
  --project=project-69f6f6fe-42ac-4d0e-8cd

kubectl create namespace staging
kubectl create namespace production
```

### Step 7 — Add GitHub Secrets

In your GitHub repo → **Settings → Secrets and variables → Actions**:

| Secret Name | Value |
|-------------|-------|
| `WIF_PROVIDER` | `projects/85539739058/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `WIF_SERVICE_ACCOUNT` | `cicd-pipeline-sa@project-69f6f6fe-42ac-4d0e-8cd.iam.gserviceaccount.com` |

---

## 12. How to Trigger a Deployment

1. Go to your GitHub repo: `https://github.com/arunponugoti1/gke-multi-env-project`
2. Click the **Actions** tab
3. Click **CI/CD Pipeline - Build, Push & Deploy** in the left sidebar
4. Click **Run workflow** → **Run workflow**
5. Watch the pipeline run — all steps should go green
6. Go to **GCP Console → Cloud Deploy → python-app-pipeline**
7. Staging deploys automatically
8. To promote to production: click the release → **Promote** → **Approve**

### Verify the deployment

```bash
# Check pods are running
kubectl get pods -n staging
kubectl get pods -n production

# Get the public IP of the staging service
kubectl get service python-web-app-svc -n staging

# Open in browser → should show "Environment: STAGING"
```

---

## 13. Troubleshooting Log — Issues Debugged and Resolved

This section documents every issue encountered during setup, the root cause, and the exact fix applied.

---

### Issue 1 — SA Key Creation Blocked by Org Policy

**Error:**
```
Service account key creation is disabled.
Organization Policy: iam.disableServiceAccountKeyCreation
```

**Root cause:**
The GCP organization has enforced a security policy that prevents downloading service account JSON keys. This is a common enterprise security control.

**Fix:**
Switched from SA key authentication to **Workload Identity Federation (WIF)**. WIF uses GitHub's built-in OIDC identity instead of a stored secret key. The `cicd.yml` workflow was updated to use:
```yaml
workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
service_account: ${{ secrets.WIF_SERVICE_ACCOUNT }}
```
And `permissions: id-token: write` was added to the workflow to allow OIDC token generation.

---

### Issue 2 — WIF Provider Creation Failed (attribute-condition)

**Error:**
```
ERROR: INVALID_ARGUMENT: The attribute condition must reference one of the provider's claims.
```

**Root cause:**
Newer GCP versions require the `--attribute-condition` flag when creating a WIF OIDC provider. Without it, GCP rejects the creation to enforce security best practices.

**Fix:**
Added `--attribute-condition` to the provider creation command:
```bash
--attribute-condition="assertion.repository=='arunponugoti1/gke-multi-env-project'"
```
This restricts authentication to ONLY the specified GitHub repo. Any other repo trying to authenticate with this pool will be rejected.

---

### Issue 3 — Cloud Deploy Pipeline Not Found

**Error:**
```
NOT_FOUND: Resource '.../deliveryPipelines/python-app-pipeline' was not found.
```

**Root cause:**
The `gcloud deploy apply --file=clouddeploy.yaml` command had never been run. The Cloud Deploy pipeline resource did not exist in GCP yet.

**Fix:**
Run once in Cloud Shell:
```bash
gcloud deploy apply --file=k8s/clouddeploy.yaml --region=us-central1 --project=PROJECT_ID
```

---

### Issue 4 — Cloud Build Cannot Write Logs (403)

**Error:**
```
The service account 85539739058-compute@developer.gserviceaccount.com does not have 
permission to write logs to Cloud Logging.
```

**Root cause:**
Cloud Deploy internally triggers Cloud Build jobs to render manifests. These jobs run as the **Compute default service account**. This SA was missing `roles/logging.logWriter`.

**Fix:**
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/logging.logWriter"
```

---

### Issue 5 — Skaffold Config Not Found in GCS

**Error:**
```
failed to download Skaffold Config file from 
"gs://us-central1.deploy-artifacts.../release-ID/staging/stable/skaffold.yaml": not found
```

**Root cause (part 1):**
The `--source=.` flag in `gcloud deploy releases create` uploaded the entire repo root. The `--skaffold-file=k8s/skaffold.yaml` path was being resolved incorrectly by Cloud Deploy when rendering. The render job (Cloud Build) was silently failing to write the rendered artifacts back to GCS because the Compute SA lacked `roles/storage.admin` (only had `objectViewer`).

**Root cause (part 2):**
The Cloud Deploy system SA (`service-PROJECT_NUMBER@gcp-sa-clouddeploy.iam.gserviceaccount.com`) lacked permissions to trigger Cloud Build render jobs and act as the Compute SA.

**Fix:**
Changed source to the `k8s/` directory directly:
```bash
--source=k8s \
--skaffold-file=skaffold.yaml   # now relative to k8s/
```

And granted required permissions:
```bash
# Compute SA — write rendered artifacts
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${COMPUTE_SA}" --role="roles/storage.admin"

# Cloud Deploy SA — run jobs + deploy to GKE
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${CLOUDDEPLOY_SA}" --role="roles/clouddeploy.jobRunner"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${CLOUDDEPLOY_SA}" --role="roles/container.developer"

# Cloud Deploy SA — act as Compute SA to trigger Cloud Build
gcloud iam service-accounts add-iam-policy-binding ${COMPUTE_SA} \
  --role="roles/iam.serviceAccountUser" \
  --member="serviceAccount:${CLOUDDEPLOY_SA}"
```

---

### Issue 6 — Skaffold Paths Wrong Inside k8s/ Directory

**Root cause:**
`k8s/skaffold.yaml` originally referenced paths as `k8s/overlays/staging`. But since `skaffold.yaml` itself lives inside `k8s/`, Skaffold resolves paths relative to its own location. So `k8s/overlays/staging` would resolve to `k8s/k8s/overlays/staging` — which doesn't exist.

**Fix:**
Updated `k8s/skaffold.yaml` to use paths relative to itself:
```yaml
# Before (wrong)
paths:
- k8s/overlays/staging

# After (correct)
paths:
- overlays/staging
```

---

### Issue 7 — ALREADY_EXISTS on Release Re-run

**Error:**
```
ALREADY_EXISTS: Resource '.../releases/release-40e4f0f-9' already exists
```

**Root cause (first occurrence):**
The release name used only `SHORT_SHA`. When the same commit was deployed again, it generated the same release name.

**Root cause (second occurrence):**
After adding `github.run_number`, clicking "Re-run jobs" in GitHub reuses the same run number, so `release-40e4f0f-9` was attempted again on re-run.

**Fix:**
Added both `github.run_number` AND `github.run_attempt` to the release name:
```bash
gcloud deploy releases create "release-${SHORT_SHA}-${{ github.run_number }}-${{ github.run_attempt }}"
```
- New trigger → `run_number` increments → unique name
- Re-run of same workflow → `run_attempt` increments → still unique

---

### Issue 8 — ImagePullBackOff (403 Forbidden)

**Error:**
```
failed to authorize: failed to fetch oauth token from 
https://us-central1-docker.pkg.dev/v2/token: 403 Forbidden
```

**Root cause:**
GKE nodes pull Docker images using the Compute default service account. The Compute SA was not granted `roles/artifactregistry.reader`, so GKE nodes were denied when trying to pull from Artifact Registry.

**Fix:**
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/artifactregistry.reader"
```

---

### Issue 9 — WIF IAM Binding Had Wrong GitHub Username

**Root cause:**
During initial setup, the placeholder `your-github-username` was not replaced before running the IAM binding command. The binding was created for `your-github-username/gcp-cicd-project` instead of `arunponugoti1/gke-multi-env-project`.

**Fix:**
Removed the wrong binding and added the correct one:
```bash
# Remove wrong
gcloud iam service-accounts remove-iam-policy-binding $SA_EMAIL \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://.../attribute.repository/your-github-username/gcp-cicd-project"

# Add correct
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://.../attribute.repository/arunponugoti1/gke-multi-env-project"
```

---

### Summary of All IAM Permissions Added

| Service Account | Role Added | Reason |
|-----------------|-----------|--------|
| `cicd-pipeline-sa` | `storage.admin` | Upload source to Cloud Deploy GCS bucket |
| `compute SA` | `logging.logWriter` | Cloud Build render job logs |
| `compute SA` | `container.developer` | Deploy jobs apply to GKE |
| `compute SA` | `storage.admin` | Write rendered manifests to GCS |
| `compute SA` | `artifactregistry.reader` | GKE nodes pull Docker images |
| `clouddeploy SA` | `clouddeploy.jobRunner` | Run deploy jobs |
| `clouddeploy SA` | `container.developer` | Apply manifests to GKE |
| `clouddeploy SA` | `iam.serviceAccountUser` on Compute SA | Trigger Cloud Build as Compute SA |

---

*Documentation written by Arun Ponugoti*
