# Deployment Guide: Healthchecks (Django) on AWS EKS

This guide covers deploying the Healthchecks Django application to **AWS EKS** with Helm and helmfile, with the database in **Amazon RDS (PostgreSQL)** and HTTPS from a **Let's Encrypt** certificate issued by cert-manager. It covers every step, the issues faced along the way with their solutions, and why Kubernetes and Helm fit this scenario.

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Why Kubernetes and Helm](#2-why-kubernetes-and-helm)
3. [Prerequisites](#3-prerequisites)
4. [Helm chart and helmfile](#4-helm-chart-and-helmfile)
5. [Secret encryption (helm-secrets + sops + age)](#5-secret-encryption-helm-secrets--sops--age)
6. [Configuration: values to set before deploying](#6-configuration-values-to-set-before-deploying)
7. [Deployment steps](#7-deployment-steps)
8. [Verification](#8-verification)
9. [Updating the application](#9-updating-the-application)
10. [Teardown](#10-teardown)
11. [Issues faced and solutions](#11-issues-faced-and-solutions)
12. [Design decisions and known limitations](#12-design-decisions-and-known-limitations)

---

## 1. Architecture

```
                    Internet
                       │
          DNS: hc.<your-domain>  (CNAME → NLB hostname)
                       │
         ┌─────────────▼──────────────┐
         │  AWS Network Load Balancer │  ← created automatically by the
         └─────────────┬──────────────┘    ingress-nginx LoadBalancer Service
  ┌────────────────────┼──────────────── EKS cluster (us-east-1) ─────────────┐
  │                    ▼                                                     │
  │        ingress-nginx controller  ── TLS cert from Secret healthchecks-tls │
  │                    │                       ▲                             │
  │                    │               cert-manager + ClusterIssuer          │
  │                    │               (Let's Encrypt, HTTP-01)              │
  │                    ▼                                                     │
  │        Service healthchecks (ClusterIP :80 → :8080)                      │
  │                    │                                                     │
  │        Deployment healthchecks (2–4 pods, HPA at 80% CPU/RAM)            │
  │          ├─ initContainer: manage.py migrate                             │
  │          └─ gunicorn :8080  ← ConfigMap + Secret via envFrom             │
  └────────────────────┼─────────────────────────────────────────────────────┘
                       │ private subnets, sslmode=require
                       ▼
         Amazon RDS PostgreSQL (db.t4g.micro, not publicly accessible)
```

The cluster and RDS share **one VPC**: RDS sits in the private subnets and only accepts connections from inside the VPC.

---

## 2. Why Kubernetes and Helm

### Kubernetes

| Need | What Kubernetes provides |
|---|---|
| **Availability** | The Deployment keeps 2 replicas running and replaces crashed pods automatically. The liveness probe restarts a hung container. |
| **Safe traffic routing** | The readiness probe removes a pod from the Service until it can actually reach the database, so users never hit a pod that isn't ready. |
| **Elastic scaling** | The HorizontalPodAutoscaler adds pods (up to 4) under load and removes them when load drops. |
| **Zero-downtime updates** | Rolling updates replace pods gradually when the image or config changes. |
| **Configuration outside the image** | The image is environment-agnostic. Database host, domain and secrets come from a ConfigMap and Secret, so moving to another database or domain needs no rebuild. |
| **Cloud integration** | A `LoadBalancer` Service makes AWS provision an NLB automatically, and cert-manager obtains and renews TLS certificates automatically. |
| **Portability** | The same chart runs on any Kubernetes cluster. Moving to another provider changes the ingress/LB settings, not the app. |

### Helm

| Need | What Helm provides |
|---|---|
| **One package for the app** | Seven resources (ConfigMap, Secret, Deployment, Service, Ingress, ClusterIssuer, HPA) are installed, upgraded and removed as one release. |
| **Templating** | The structure lives in `templates/`, and environment-specific settings live in `values.yaml`. Changing the image tag, domain or DB host is a values change, not a manifest edit. |
| **History and rollback** | `helm history` lists every revision, and `helm rollback healthchecks <rev>` reverts a bad deploy. |
| **Reusing third-party software** | ingress-nginx and cert-manager are installed from their official charts with pinned versions instead of hand-written YAML. |
| **Secret handling** | With helm-secrets, encrypted values files can be committed to git and are decrypted only in memory at deploy time. |

### helmfile

helmfile describes the **whole environment** declaratively: which charts, which versions, which values, and in which order (`needs`). `helmfile apply` brings the cluster in line with the file and shows a diff first. It works much like `terraform plan/apply`, but for Helm releases.

---

## 3. Prerequisites

| Tool | Version used | Purpose |
|---|---|---|
| AWS CLI | 2.36 | RDS, verification, cleanup |
| eksctl | 0.231.0 | Creates the EKS cluster and VPC |
| kubectl | | Kubernetes CLI |
| Helm | **v4.3.0** | Package manager |
| helmfile | 1.8.1 | Environment definition |
| helm-secrets | 4.7.9 (3 plugins on Helm 4) | Decrypts secrets at deploy time |
| helm-diff | 3.15.13 | Required by `helmfile diff/apply` |
| sops / age | 3.13.3 / 1.3.2 | Encryption of `secrets-values.yaml` |

You also need an AWS account with permissions for EKS, EC2, CloudFormation, IAM and RDS, and a **domain whose DNS you control** (required for Let's Encrypt).

### Install the tools (macOS)
```bash
brew install awscli eksctl kubectl helm helmfile sops age gnupg
```

### Install the Helm plugins (Helm 4)
Helm 4 verifies plugin signatures, so import the helm-secrets author's public key first (see issue #5):
```bash
mkdir -p ~/.config/helm
curl -sL https://github.com/jkroepke.gpg | gpg --dearmor > ~/.config/helm/jkroepke.gpg
K=~/.config/helm/jkroepke.gpg
V=4.7.9
helm plugin install --keyring $K https://github.com/jkroepke/helm-secrets/releases/download/v$V/secrets-$V.tgz
helm plugin install --keyring $K https://github.com/jkroepke/helm-secrets/releases/download/v$V/secrets-getter-$V.tgz
helm plugin install --keyring $K https://github.com/jkroepke/helm-secrets/releases/download/v$V/secrets-post-renderer-$V.tgz

helmfile init        # installs helm-diff; answer "n" to optional plugins (s3, helm-git)
helm plugin list     # diff, secrets, secrets-getter, secrets-post-renderer
```

### Container image
The app image `melnykv2/healthchecks` listens on **port 8080** (`gunicorn hc.wsgi:application --bind 0.0.0.0:8080`). EKS `t3` nodes are **amd64**, so the tag **`v1.4`** (amd64) is used. `v1.5` is the arm64 build.

---

## 4. Helm chart and helmfile

### 4.1 Templates

| Template | Content | Values used |
|---|---|---|
| `configmap.yaml` | All non-secret env vars. `range` over the map, `quote` keeps every value a string | `config.*` |
| `secrets.yaml` | Secret env vars. `b64enc \| quote`: plain values in, base64 out | `secrets.*` (from the encrypted file) |
| `deployment.yaml` | 2 replicas, port 8080, `envFrom` ConfigMap + Secret, `migrate` initContainer, probes, resources | `replicaCount`, `image.*`, `containerPort`, `resources` |
| `service.yaml` | ClusterIP, port 80 → named container port `http` | `service.type`, `service.port` |
| `ingress.yaml` | Host rule + TLS, `cert-manager.io/cluster-issuer` annotation | `ingress.className`, `ingress.host`, `ingress.clusterIssuer` |
| `cluster-issuer.yaml` | `letsencrypt-prod` ACME ClusterIssuer with an HTTP-01 solver | `letsencrypt.email`, `ingress.className` |
| `hpa.yaml` | `autoscaling/v2`, CPU and memory targets | `autoscaling.*` |

All resource names come from `{{ .Release.Name }}`, so the references between them always match. The release must be installed as **`healthchecks`** (helmfile does this).

### 4.2 How the requirements map to the chart

| Requirement | Implementation |
|---|---|
| ConfigMap for env vars | `templates/configmap.yaml` ← `values.yaml: config` |
| Secret, encrypted | `templates/secrets.yaml` ← `secrets-values.yaml` (sops/age, see §5) |
| 2 replicas | `replicaCount: 2`, `autoscaling.minReplicas: 2` |
| Port 8080 | `containerPort: 8080` |
| ConfigMap + Secret propagated | `envFrom: configMapRef + secretRef` on the app and the migrate container |
| Readiness + liveness probes | HTTP `/api/v3/status/` + TCP `:8080` |
| Service ClusterIP | `service.type: ClusterIP` |
| Ingress controller that provisions an LB | ingress-nginx (helmfile) → `LoadBalancer` Service → AWS NLB |
| cert-manager + Let's Encrypt | cert-manager (helmfile) + `letsencrypt-prod` ClusterIssuer + Ingress annotation |
| HPA 2→4 at 80% CPU or RAM | `hpa.yaml`, two `Resource` metrics at `averageUtilization: 80` |

### 4.3 Probe design
- **Readiness → `httpGet /api/v3/status/`.** Healthchecks' status endpoint runs `SELECT 1` against the database, so a pod only receives traffic when it can actually serve requests. The trailing slash matters (see issue #3).
- **Liveness → `tcpSocket :8080`.** It deliberately does **not** check the database. If RDS has an outage, a DB-based liveness probe would restart *every* pod, which doesn't fix the database and turns a DB problem into a full app outage.
- The readiness probe sends `Host: localhost`, because kubelet probes the pod IP directly and Django rejects hosts not in `ALLOWED_HOSTS` (issue #2). `localhost` is in `ALLOWED_HOSTS` only for this purpose.

### 4.4 helmfile (`helmfile/helmfile.yaml`)
Summary of the file (see the file itself for the exact YAML):
```text
helmDefaults:
  wait: true                 # each release waits for Ready before the next starts
releases:
  - ingress-nginx  4.15.1   # NLB via service.beta.kubernetes.io/aws-load-balancer-type: nlb
  - cert-manager   v1.21.2  # crds.enabled: true
  - healthchecks   ../helm_chart
      needs: [cert-manager, ingress-nginx]
      secrets: [../helm_chart/secrets-values.yaml]
```
- **Pinned versions** so a later run can't silently pull a breaking upgrade.
- **`needs`** ensures the IngressClass and the cert-manager CRDs/webhook exist before the app's Ingress and ClusterIssuer are created.
- **`wait: true`** prevents `failed calling webhook "webhook.cert-manager.io"`, which would happen if the ClusterIssuer were created before cert-manager's webhook was ready.
- **metrics-server** (needed by the HPA) isn't in the helmfile, because eksctl installs it as a default EKS add-on (issue #11).

---

## 5. Secret encryption (helm-secrets + sops + age)

| Tool | Role |
|---|---|
| **age** | Key pair: the public key encrypts, the private key decrypts |
| **sops** | Encrypts YAML **values** and leaves the keys readable, so diffs show *which* secret changed but not its value |
| **helm-secrets** | Decrypts the file in memory at deploy time and passes it to Helm |

### Create a key
```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt                    # prints "Public key: age1..."
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"   # add to ~/.zshrc
```
The private key (`keys.txt`) is never committed. Back it up, because without it the secrets can't be decrypted.

### `.sops.yaml` (committed, contains only the **public** key)
```yaml
creation_rules:
  - path_regex: secrets-values.*\.yaml$
    age: age1<your-public-key>
```
The regex is deliberately narrow so it can't match `templates/secrets.yaml`.

### Workflow
```bash
sops -e -i helm_chart/secrets-values.yaml     # encrypt in place (once)
sops helm_chart/secrets-values.yaml           # edit: decrypts in $EDITOR, re-encrypts on save
```
helmfile decrypts the file automatically through the `secrets:` key. `.gitignore` contains `*.dec`, because helm-secrets briefly writes a decrypted `.dec` copy while rendering.

The encrypted file in git looks like this:
```yaml
secrets:
    SECRET_KEY: ENC[AES256_GCM,data:...,type:str]
    DB_PASSWORD: ENC[AES256_GCM,data:...,type:str]
sops:
    age: [...]
```

---

## 6. Configuration: values to set before deploying

The repository contains the values used for this deployment (domain `vadymthebest.com`, region `us-east-1`, a specific RDS endpoint, and so on). To deploy into another account or with another domain, replace the values below. Everything marked **must** is environment-specific.

### 6.1 `helm_chart/values.yaml`

| Key | Current value | Replace with | Notes |
|---|---|---|---|
| `config.DB_HOST` | `healthchecks-db.cwv2a4uw41qv.us-east-1.rds.amazonaws.com` | **must:** your RDS endpoint | Set after RDS is created (§7.3). This instance no longer exists |
| `config.DB_NAME` | `hc` | the RDS `--db-name` | Must match what RDS was created with |
| `config.DB_USER` | `hc` | the RDS `--master-username` | Must match what RDS was created with |
| `config.DB_PORT` | `5432` | usually unchanged | |
| `config.DB_SSLMODE` | `require` | usually unchanged | Encrypts app ↔ RDS traffic |
| `config.SITE_ROOT` | `https://hc.vadymthebest.com` | **must:** `https://<your-host>` | Must match `ingress.host` |
| `config.ALLOWED_HOSTS` | `hc.vadymthebest.com,localhost` | **must:** `<your-host>,localhost` | Keep `localhost` for the readiness probe. A mismatch makes Django answer `400` |
| `ingress.host` | `hc.vadymthebest.com` | **must:** your domain/subdomain | You must control its DNS |
| `ingress.className` | `nginx` | the IngressClass of your controller | |
| `ingress.clusterIssuer` | `letsencrypt-prod` | usually unchanged | |
| `letsencrypt.email` | the author's email | **must:** your email | Receives Let's Encrypt expiry warnings |
| `image.repository` | `melnykv2/healthchecks` | your image, if you build your own | |
| `image.tag` | `v1.4` (amd64) | the tag matching your **node CPU architecture** | A wrong arch gives `ErrImagePull` / `exec format error` |
| `resources`, `replicaCount`, `autoscaling.*` | 100m/256Mi, 2, 2–4 @ 80% | optional tuning | Keep the memory request above the app's idle usage (issue #4) |

**Keep these three in sync:** `ingress.host`, `config.SITE_ROOT` and `config.ALLOWED_HOSTS`.

### 6.2 Secrets: `helm_chart/secrets-values.yaml` and `.sops.yaml`

The committed file is encrypted for **the author's age key**. Nobody else can decrypt it, so a new deployer creates their own:
```bash
# 1. Put YOUR age public key into .sops.yaml (see §5)

# 2. Write the secrets in PLAIN text (the template base64-encodes them)
cat > helm_chart/secrets-values.yaml <<'YAML'
secrets:
  SECRET_KEY: "<output of: openssl rand -base64 48>"
  DB_PASSWORD: "<RDS master password>"
YAML

# 3. Encrypt in place before committing
sops -e -i helm_chart/secrets-values.yaml
```

| Key | Notes |
|---|---|
| `SECRET_KEY` | A long random string. Django uses it to sign sessions and tokens |
| `DB_PASSWORD` | Becomes the RDS master password (§7.2 reads it from this file). RDS forbids `/`, `"`, `@` and spaces. Plain text only, never pre-base64-encoded (issue #6) |

### 6.3 `infra/eks-cluster.yaml`

| Key | Current value | Notes |
|---|---|---|
| `metadata.name` | `healthchecks` | Cluster name. Must be unique in the region |
| `metadata.region` | `us-east-1` | Your region. RDS must be in the **same** region and VPC |
| `managedNodeGroups[].instanceType` | `t3.small` (amd64) | With a Graviton type (`t4g.*`, arm64), switch `image.tag` to the arm64 image |
| `desiredCapacity` / `minSize` / `maxSize` | `2` | Node count |

### 6.4 `helmfile/helmfile.yaml`

| Key | Notes |
|---|---|
| `releases[].version` | Pinned chart versions. Update deliberately, checking `helm search repo <chart>` |
| `healthchecks.namespace` | `default`. Change it to use a dedicated namespace |
| ingress-nginx `aws-load-balancer-type: nlb` | AWS-specific annotation |

### 6.5 Outside the repository

| What | Value |
|---|---|
| DNS record | `CNAME <subdomain>` → the ingress-nginx load balancer hostname (§7.6) |
| `SOPS_AGE_KEY_FILE` | Path to your age private key, set wherever helm-secrets runs (issue #7) |
| AWS region | `AWS_REGION` / `AWS_DEFAULT_REGION` / `~/.aws/config` must match `metadata.region`. Environment variables override the config file (issue #12) |
| kube context | `kubectl config current-context` must point at the target cluster before `helmfile sync/apply` |

---

## 7. Deployment steps

All commands run from the repository root. Set the region for the session first:
```bash
export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
aws configure list | grep region           # must show us-east-1
```

### 7.1 Create the EKS cluster
`infra/eks-cluster.yaml`:
```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: healthchecks
  region: us-east-1
vpc:
  nat:
    gateway: Disable                 # saves ~$1/day
managedNodeGroups:
  - name: default
    instanceType: t3.small           # amd64 → image tag v1.4
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    privateNetworking: false         # nodes in public subnets, so they pull images without a NAT
```
```bash
eksctl create cluster -f infra/eks-cluster.yaml --dry-run   # review the full config first
eksctl create cluster -f infra/eks-cluster.yaml             # ~15–20 min
```
eksctl creates (via CloudFormation) the VPC with 2 AZs and public and private subnets, the control plane, 2 nodes, and the default add-ons `vpc-cni`, `kube-proxy`, `coredns` and `metrics-server`. When it finishes, it switches your kubectl context to the new cluster.

```bash
kubectl config current-context     # ...@healthchecks.us-east-1.eksctl.io
kubectl get nodes                  # 2 × Ready
kubectl get deployment metrics-server -n kube-system   # 2/2
```

### 7.2 Create RDS (can start while the control plane is still being built)
The VPC appears a few minutes into `eksctl create`. RDS can be created then, in parallel, which shortens the total time.

```bash
# Look up the eksctl VPC and its private subnets
VPC=$(aws ec2 describe-vpcs --filters Name=tag:alpha.eksctl.io/cluster-name,Values=healthchecks \
  --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=map-public-ip-on-launch,Values=false \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text

# Subnet group: RDS may only use the private subnets
aws rds create-db-subnet-group --db-subnet-group-name healthchecks-db \
  --db-subnet-group-description "Private subnets of the healthchecks EKS VPC" \
  --subnet-ids <private-subnet-a> <private-subnet-b>

# Security group: Postgres only from inside the VPC
SG=$(aws ec2 create-security-group --group-name healthchecks-db \
  --description "Postgres access from inside the EKS VPC" \
  --vpc-id $VPC --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG \
  --protocol tcp --port 5432 --cidr 192.168.0.0/16          # eksctl's default VPC CIDR

# The database
aws rds create-db-instance --db-instance-identifier healthchecks-db \
  --engine postgres --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 \
  --db-name hc --master-username hc \
  --master-user-password "$(sops -d --extract '["secrets"]["DB_PASSWORD"]' helm_chart/secrets-values.yaml)" \
  --db-subnet-group-name healthchecks-db --vpc-security-group-ids $SG \
  --no-publicly-accessible --no-multi-az \
  --backup-retention-period 0 --no-deletion-protection
```
- The master password is read **directly from the encrypted file**. It's never typed, never in shell history, and guaranteed to match the app's Secret.
- `--db-name hc` / `--master-username hc` match `DB_NAME` / `DB_USER` in `values.yaml`.
- `--no-multi-az` and `--backup-retention-period 0` keep it cheap and fast to create, which is fine for a test but not for production (§12).

### 7.3 Set the RDS endpoint
```bash
aws rds wait db-instance-available --db-instance-identifier healthchecks-db     # 5–10 min
aws rds describe-db-instances --db-instance-identifier healthchecks-db \
  --query 'DBInstances[0].Endpoint.Address' --output text
```
Put the endpoint into `helm_chart/values.yaml` → `config.DB_HOST`, then commit.

### 7.4 Render and check before deploying
```bash
helmfile -f helmfile/helmfile.yaml lint
helmfile -f helmfile/helmfile.yaml template --selector name=healthchecks \
  | grep -E "image:|host:|DB_HOST|DB_SSLMODE|SITE_ROOT|ALLOWED_HOSTS|cluster-issuer"
```
Check the image tag (amd64), the domain in all three places, the RDS endpoint and `letsencrypt-prod`. This step caught a wrong `ALLOWED_HOSTS` value before anything was deployed (issue #9).

### 7.5 Deploy
```bash
kubectl config current-context                 # always confirm the target cluster
helmfile -f helmfile/helmfile.yaml sync        # first install (issue #10); later changes use "apply"
```
Order (thanks to `needs` and `wait: true`):
1. **ingress-nginx.** Its `LoadBalancer` Service makes AWS create an **NLB**.
2. **cert-manager.** helmfile waits until its webhook is Ready.
3. **healthchecks.** The `migrate` init container applies migrations to **RDS**, then 2 app pods start, and the Ingress and ClusterIssuer are created.

```bash
kubectl get pods -A | grep -E "ingress-nginx|cert-manager|healthchecks"   # all Running
kubectl logs deploy/healthchecks -c migrate | tail -3                     # "Applying ... OK"
kubectl get svc -n ingress-nginx ingress-nginx-controller                 # EXTERNAL-IP = NLB hostname
```

### 7.6 DNS
At your DNS provider, add:

| Type | Name | Value | TTL |
|---|---|---|---|
| CNAME | `hc` | `<NLB hostname>.elb.us-east-1.amazonaws.com` | 300 |

Use a **CNAME**, not an A record: an NLB has a DNS name, and AWS can change the IPs behind it.
```bash
dig +short hc.<your-domain>        # NLB hostname + IPs
```

### 7.7 Certificate
cert-manager sees the `cert-manager.io/cluster-issuer` annotation on the Ingress, creates a `Certificate`, and solves the **HTTP-01** challenge through ingress-nginx. Before asking Let's Encrypt to validate, it runs a **self-check** that the challenge URL is reachable through DNS, so it waits for the DNS record instead of using up Let's Encrypt rate limits.
```bash
kubectl get certificate healthchecks-tls -w     # READY → True
kubectl describe challenge -A                   # if it stays pending: shows the reason
```
If the challenge was created before the DNS record existed, it may stay pending for a while (issue #13).

---

## 8. Verification

| Check | Command / result |
|---|---|
| App + database | `curl https://hc.<your-domain>/api/v3/status/` → `OK` |
| Certificate | `openssl s_client -connect hc.<your-domain>:443 ... \| openssl x509 -noout -issuer` → **Let's Encrypt**, valid 90 days, renewed automatically by cert-manager |
| HTTP → HTTPS | `http://` → `308` redirect (ingress-nginx does this automatically when the Ingress has TLS) |
| Browser | Padlock + Healthchecks login page |
| Resources | `kubectl get deploy,svc,ingress,hpa,configmap,secret` → Deployment 2/2, Service `ClusterIP`, Ingress with the host |
| HPA metrics | `kubectl get hpa healthchecks` → `cpu: x%/80%, memory: x%/80%`, min 2 / max 4 |
| Releases | `helm list -A` → ingress-nginx, cert-manager, healthchecks deployed |

### HPA load test
Terminal 1:
```bash
kubectl get hpa healthchecks -w
```
Terminal 2:
```bash
kubectl run load --rm -it --restart=Never --image=busybox -- \
  sh -c 'while true; do wget -q -O- --header="Host: localhost" http://healthchecks/api/v3/status/ >/dev/null; done'
```
CPU rises above 80%, and `REPLICAS` grows from 2 to 4. Ctrl+C stops the load and deletes the pod.

---

## 9. Updating the application

```bash
# edit helm_chart/values.yaml (or `sops helm_chart/secrets-values.yaml`)
helmfile -f helmfile/helmfile.yaml diff      # preview
helmfile -f helmfile/helmfile.yaml apply     # upgrades only the releases that changed
helm history healthchecks                    # revisions
helm rollback healthchecks <revision>        # revert
```
Changes to the ConfigMap or Secret **don't restart running pods**, because env vars are read only at container start. After such changes run:
```bash
kubectl rollout restart deployment healthchecks
```
Image tag changes do trigger a rolling update automatically.

---

## 10. Teardown

The order matters. Deleting the cluster first would leave the NLB running (only Kubernetes knows about it), and the RDS security group would block VPC deletion.

```bash
# 1. Releases first → the LoadBalancer Service is removed → AWS deletes the NLB
helmfile -f helmfile/helmfile.yaml destroy
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text   # must be empty

# 2. RDS and its network objects (they live inside the eksctl VPC)
aws rds delete-db-instance --db-instance-identifier healthchecks-db \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier healthchecks-db
aws rds delete-db-subnet-group --db-subnet-group-name healthchecks-db
aws ec2 delete-security-group --group-id <rds-sg-id>

# 3. Cluster + VPC
eksctl delete cluster -f infra/eks-cluster.yaml --wait

# 4. Remove the DNS CNAME, so it doesn't point at a load balancer that no longer exists
```
Afterwards, verify that nothing billable remains in the region: EKS clusters, CloudFormation stacks, EC2 instances, the VPC, load balancers, unattached EBS volumes, Elastic IPs, NAT gateways, RDS instances and snapshots, and CloudWatch log groups.

**Cost:** the test environment existed for about 1.5 hours (EKS control plane, 2 × t3.small, NLB, db.t4g.micro).

---

## 11. Issues faced and solutions

### Application and probes

**#1. The app listened on port 8000, but the task requires 8080.**
*Solution:* the image's Dockerfile was changed to `EXPOSE 8080` and `CMD ["gunicorn", "hc.wsgi:application", "--bind", "0.0.0.0:8080"]`. `GUNICORN_CMD_ARGS` doesn't help, because a `--bind` on the command line takes precedence. Separate images were built for amd64 (`v1.4`, used on EKS) and arm64 (`v1.5`).

**#2. Readiness probe failed with HTTP 400.**
*Cause:* kubelet sends probes with `Host: <pod-IP>`, which isn't in Django's `ALLOWED_HOSTS`, so Django answers `400 DisallowedHost` (`Readiness probe failed: HTTP probe failed with statuscode: 400`).
*Solution:* add `httpHeaders: [{name: Host, value: localhost}]` to the probe, and `localhost` to `ALLOWED_HOSTS`. The probe goes directly to the pod IP (not through DNS or the Ingress), so `localhost` works regardless of the domain.

**#3. Readiness probe passed without ever checking the database.**
*Cause:* the path was `/api/v3/status` (no trailing slash). Django redirects it with `301`, and Kubernetes treats any 2xx–3xx response as success.
*Solution:* use `/api/v3/status/`. Confirmed with `curl -si ... | head -1` → `301` vs `200`.

**#4. HPA never scaled back down after a load test.**
*Symptom:* long after the load stopped: `cpu: 2%/80%, memory: 65%/80%`, still 4 replicas.
*Cause:* HPA formula `desired = ceil(current × usage / target) = ceil(4 × 65 / 80) = 4`. The idle memory of a gunicorn pod (~83Mi) was already 65% of a 128Mi request, and Python processes don't release memory.
*Solution:* set the memory request to a realistic `256Mi` (idle ≈ 32%). Afterwards the HPA showed `memory: 31%/80%` and could scale down to 2.

### Helm, secrets and plugins

**#5. Installing helm-secrets on Helm 4.**
*Symptom 1:* most tutorials show `helm plugin install https://github.com/jkroepke/helm-secrets`, which is the Helm 3 method. On Helm 4, helm-secrets is split into three plugins (`secrets`, `secrets-getter`, `secrets-post-renderer`) installed from release `.tgz` files.
*Symptom 2:* `plugin verification failed: open ~/.gnupg/pubring.gpg: no such file or directory`. Helm 4 verifies plugin signatures by default and needs a binary GPG keyring.
*Solution:* `curl -sL https://github.com/jkroepke.gpg | gpg --dearmor > ~/.config/helm/jkroepke.gpg`, then `helm plugin install --keyring ~/.config/helm/jkroepke.gpg <url>` (§3). Verification was kept on instead of using `--verify=false`.
*Note:* `helmfile init` installed helm-diff **without** signature verification ("Skipping plugin signature verification").

**#6. `password authentication failed for user "hc"` after the first Helm install.**
*Cause:* `secrets-values.yaml` contained **already base64-encoded** values, and the template's `b64enc` encoded them again. This was confirmed by comparing lengths: the password was 20 characters instead of 14 (exactly the base64 length of 14 bytes).
*Solution:* `sops helm_chart/secrets-values.yaml` → replace the values with plain text → upgrade. Rule: values files hold plain text, and the template does the encoding.

**#7. sops couldn't decrypt in non-interactive shells.**
*Symptom:* `Failed to get the data key required to decrypt the SOPS file ... Did not find keys in locations ... SOPS_AGE_KEY_FILE`.
*Cause:* the key path was set only in `~/.zshrc`, which isn't loaded by every shell (scripts, IDE terminals, CI). On macOS, sops' default key location is `~/Library/Application Support/sops/age/keys.txt`, not `~/.config/...`.
*Solution:* make sure `SOPS_AGE_KEY_FILE` is set wherever helm-secrets runs.

**#8. `Chart.yaml` accidentally overwritten with an empty file.**
*Symptom:* `helm lint`: `Chart.yaml: name is required ... unable to load chart`.
*Solution:* restored the content. The repo had no commits yet, so git couldn't help. Lesson: commit after every working step.

**#9. Wrong `ALLOWED_HOSTS` caught before deploying.**
`ALLOWED_HOSTS` was set to `vadymthebest.com` instead of `hc.vadymthebest.com`, which would have made Django answer 400 to every request. It was caught by rendering the chart (§7.4) before creating any cloud resources.

**#10. The first `helmfile apply` failed at the diff stage.**
*Symptom:* `error validating data: the server is currently unable to handle the request` for the healthchecks release.
*Cause:* (a) the metrics-server API had just started and was briefly unavailable, and (b) helm-diff validates the chart against the live cluster, but the chart contains a `ClusterIssuer`, whose CRD doesn't exist until cert-manager is installed.
*Solution:* `helmfile sync` for the first install (installs in `needs` order without a diff). Every later change uses `diff`/`apply` normally.

### AWS

**#11. metrics-server conflict on EKS.**
eksctl 0.231 installs `metrics-server` as a default EKS add-on (`default addons metrics-server, vpc-cni, kube-proxy, coredns ... will install them as EKS addons`). A metrics-server release in the helmfile would have conflicted with the add-on's resources, so it was removed.

**#12. RDS subnet group creation: "Some input subnets ... are invalid".**
*Cause:* the shell had `AWS_DEFAULT_REGION=eu-central-1` set, which **overrides** `~/.aws/config` (us-east-1). RDS looked for the us-east-1 subnets in Frankfurt. eksctl wasn't affected, because the region is set explicitly in `infra/eks-cluster.yaml`.
*Solution:* `export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1` (or `--region us-east-1`). `aws configure list` shows which region applies and where it comes from.

**#13. Let's Encrypt certificate stuck in `pending` after DNS had propagated.**
*Symptom:* `Waiting for HTTP-01 challenge propagation: failed to perform self check ... lookup hc.vadymthebest.com on 10.100.0.10:53: no such host`, although public DNS checkers already showed the CNAME.
*Cause:* cert-manager's self-check ran **before** the DNS record existed, and the cluster's resolver cached the `NXDOMAIN` answer. The domain's SOA allows negative caching for 3601 seconds.
*Solution:* waited for the negative cache to expire (it cleared within minutes). cert-manager then validated the challenge and issued the certificate. No Let's Encrypt rate limit was used, because the self-check only contacts Let's Encrypt after it passes. Lesson: create the DNS record as early as possible, or use cert-manager's `waitInsteadOfSelfCheck` option.

**#14. Dangling DNS record after teardown.** The CNAME still pointed at the deleted NLB. It was removed to avoid a potential subdomain-takeover risk.

### Choices

**#15. Cloud provider.** DigitalOcean required a $10 prepayment to verify the account, so AWS was used. A benefit: EKS and RDS share one VPC, so database traffic stays private.

**#16. Choosing the ingress controller on AWS.**
- **AWS Load Balancer Controller (ALB)** was rejected: an ALB only serves certificates from AWS ACM and can't use the Let's Encrypt certificate that cert-manager stores in a Kubernetes Secret. That would make the cert-manager requirement pointless. It also needs IAM/OIDC setup.
- **ingress-nginx** was chosen: it terminates TLS with the cert-manager Secret, and its `LoadBalancer` Service makes AWS create an **NLB** (`aws-load-balancer-type: nlb`). Note that the upstream ingress-nginx project has been retired (maintenance ended in March 2026). For a long-lived deployment, a maintained controller such as Traefik would be the better choice.

**#17. Possible first-deploy race in migrations.**
Both replicas run `manage.py migrate` in their init containers at the same time. On a brand-new database one may fail once and restart. This didn't happen in the deploy, but it's a known limitation of the initContainer approach (§12).

---

## 12. Design decisions and known limitations

| Decision | Reason | Production alternative |
|---|---|---|
| Nodes in **public subnets**, no NAT Gateway | Saves ~$1/day; nodes pull images from Docker Hub directly | Private nodes behind a NAT Gateway |
| RDS **single-AZ, no backups** | Cost and creation speed for a short-lived test | Multi-AZ, automated backups, deletion protection |
| RDS reachable from the whole VPC CIDR | Simple rule | Allow only the node / cluster security group |
| Migrations in an **initContainer** | Simple, runs before every pod starts | A Helm `pre-install/pre-upgrade` hook Job (runs once, no race) |
| `replicas: 2` set in the Deployment **and** HPA min 2 | Meets the "two replicas" requirement explicitly | Omit `replicas` when the HPA is enabled, so `helm upgrade` doesn't reset the scaled count |
| No `checksum/config` annotation | Not required by the task | Automatic rollout when the ConfigMap/Secret changes |
| Prod Let's Encrypt issuer only | Minimal setup | Test with the staging issuer first to avoid rate limits |
| Separate image tags per architecture | Built separately | One multi-arch tag |
| Release in the `default` namespace | Simplicity | A dedicated namespace |
| ingress-nginx | Works with cert-manager, provisions an NLB | A maintained controller (e.g. Traefik), since ingress-nginx is retired |
| Healthchecks `sendalerts` worker not deployed | Outside the assignment scope | A second Deployment running `manage.py sendalerts` |
