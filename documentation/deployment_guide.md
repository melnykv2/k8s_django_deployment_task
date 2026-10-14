# Deployment Guide: Healthchecks (Django) on Kubernetes

This guide covers how the Healthchecks Django application was deployed to Kubernetes, first locally on **minikube** and then on **AWS EKS** with the database in **Amazon RDS**. It records every step, the problems that came up along the way with their solutions, and why Kubernetes and Helm fit this scenario.

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Why Kubernetes and Helm](#2-why-kubernetes-and-helm)
3. [Tools used](#3-tools-used)
4. [Approach](#4-approach)
5. [Phase 1: Raw manifests on minikube](#5-phase-1-raw-manifests-on-minikube)
6. [Phase 2: Helm chart](#6-phase-2-helm-chart)
7. [Secret encryption (helm-secrets + sops + age)](#7-secret-encryption-helm-secrets--sops--age)
8. [Phase 3: Deployment to AWS](#8-phase-3-deployment-to-aws)
9. [Verification](#9-verification)
10. [Teardown](#10-teardown)
11. [Issues faced and solutions](#11-issues-faced-and-solutions)
12. [Design decisions and known limitations](#12-design-decisions-and-known-limitations)
13. [Values to replace for your own deployment](#13-values-to-replace-for-your-own-deployment)

---

## 1. Architecture

```
                    Internet
                       │
          DNS: hc.vadymthebest.com  (CNAME → NLB hostname, Namecheap)
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

---

## 2. Why Kubernetes and Helm

### Kubernetes

| Need | What Kubernetes provides |
|---|---|
| **Availability** | The Deployment keeps 2 replicas running and replaces crashed pods automatically. The liveness probe restarts a hung container. |
| **Safe traffic routing** | The readiness probe removes a pod from the Service until it can actually reach the database, so users never hit a pod that isn't ready. |
| **Elastic scaling** | The HorizontalPodAutoscaler adds pods (up to 4) under load and removes them when load drops. This was verified on both minikube and EKS. |
| **Zero-downtime updates** | Rolling updates replace pods gradually when the image or config changes. |
| **Configuration outside the image** | The same image runs locally and on AWS. Only the ConfigMap/Secret differ (for example `DB_HOST` changed from an in-cluster Postgres to RDS without rebuilding anything). |
| **Cloud integration** | A `LoadBalancer` Service makes AWS provision an NLB automatically, and cert-manager obtains and renews TLS certificates automatically. |
| **Portability** | The same manifests ran on minikube and EKS. Moving to another provider changes the ingress/LB settings, not the app. |

### Helm

| Need | What Helm provides |
|---|---|
| **One package for the app** | Seven resources (ConfigMap, Secret, Deployment, Service, Ingress, ClusterIssuer, HPA) are installed, upgraded and removed as one release. |
| **Templating** | The structure lives in `templates/`, and environment-specific settings live in `values.yaml`. Changing the image tag, domain or DB host is a values change, not a manifest edit. |
| **History and rollback** | `helm history` lists every revision, and `helm rollback healthchecks <rev>` reverts a bad deploy. |
| **Reusing third-party software** | ingress-nginx and cert-manager were installed from their official charts with pinned versions instead of hand-written YAML. |
| **Secret handling** | With helm-secrets, encrypted values files can be committed to git and are decrypted only in memory at deploy time. |

### helmfile

helmfile describes the **whole environment** declaratively: which charts, which versions, which values, and in which order (`needs`). `helmfile apply` brings the cluster in line with the file and shows a diff first. It works much like `terraform plan/apply`, but for Helm releases.

---

## 3. Tools used

| Tool | Version | Purpose |
|---|---|---|
| minikube | Kubernetes v1.37.0, docker driver | Local practice cluster |
| kubectl | | Kubernetes CLI |
| Helm | **v4.3.0** | Package manager |
| helmfile | 1.8.1 | Environment definition |
| helm-secrets | 4.7.9 (3 plugins for Helm 4) | Decrypt secrets at deploy time |
| helm-diff | 3.15.13 | Required by `helmfile diff/apply` |
| sops / age | 3.13.3 / 1.3.2 | Encryption of `secrets-values.yaml` |
| eksctl | 0.231.0 | Creates the EKS cluster and VPC |
| AWS CLI | 2.36 | RDS and cleanup |
| Docker buildx | | Builds images for amd64 and arm64 |

---

## 4. Approach

The work was done in three phases, each one building on the previous:

1. **Raw Kubernetes manifests on minikube.** Learn each resource and debug it in isolation.
2. **Convert the manifests into a Helm chart.** Add encrypted secrets and a helmfile, and test on minikube again.
3. **Deploy to AWS.** EKS, RDS, NLB, a real domain and a real Let's Encrypt certificate. Then tear everything down.

---

## 5. Phase 1: Raw manifests on minikube

### 5.1 Cluster
```bash
minikube start
minikube addons enable ingress          # nginx ingress controller
minikube addons enable metrics-server   # required by the HPA
```

### 5.2 Application image
The app is the open-source **Healthchecks** project. Relevant facts were taken from the image's `hc/settings.py`:
- It switches to PostgreSQL only if `DB=postgres`, and reads `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` and `DB_SSLMODE`.
- It reads `SECRET_KEY`, `ALLOWED_HOSTS`, `SITE_ROOT` and `DEBUG`.
- It has a health endpoint, `/api/v3/status/`, which runs `SELECT 1` against the database.

The image was rebuilt to listen on **port 8080** (the original bound to 8000), and pushed as `melnykv2/healthchecks:v1.5` (arm64, for the Apple Silicon Mac) and `:v1.4` (amd64, for EKS nodes). See issues #1 and #2.

### 5.3 Local database
`local/postgres.yaml` runs `postgres:16` with a ClusterIP Service named `postgres`. Its password comes from the **same Secret key** (`DB_PASSWORD`) the app uses, so the two can't drift apart. This file is deliberately **not** part of the chart, because production uses RDS.

### 5.4 Resources, in the order they were written and tested

| Step | Resource | How it was verified |
|---|---|---|
| 1 | **Secret** (`SECRET_KEY`, `DB_PASSWORD`) | Decoded the stored value with `base64 -d` |
| 2 | **Postgres** Deployment + Service | `psql` from a throwaway client pod through the Service DNS name |
| 3 | **ConfigMap** (all non-secret env vars, keys = env var names) | `kubectl get configmap -o yaml` |
| 4 | **Deployment**: 2 replicas, `envFrom` ConfigMap + Secret, `migrate` initContainer | `kubectl port-forward` + `curl /api/v3/status/` → `OK` |
| 5 | **Probes and resources** | Pods `1/1`. Also reproduced the probe failure on purpose (issue #4) |
| 6 | **Service** (ClusterIP 80 → 8080) | `kubectl get endpoints` showed 2 IPs. curl from a pod returned `OK` |
| 7 | **Ingress** (`healthchecks.local`) | `minikube tunnel` + `/etc/hosts` → login page in the browser |
| 8 | **HPA** (2–4, 80% CPU/memory) | busybox load loop → scaled to 4 replicas |
| 9 | **cert-manager** + self-signed ClusterIssuer + Ingress TLS | Certificate `READY True`, `curl -k https://...` → `OK` |

Let's Encrypt can't validate a domain that only exists on a laptop, so locally a **self-signed** issuer was used to practice the same flow (annotation → Certificate → TLS Secret → HTTPS).

### 5.5 Probe design
- **Readiness → `httpGet /api/v3/status/`.** This endpoint checks the DB, so a pod only receives traffic when it can actually serve requests.
- **Liveness → `tcpSocket :8080`.** It deliberately does **not** check the DB. If the database has an outage, a DB-based liveness probe would restart *every* pod, which doesn't fix the database and turns a DB problem into a full app outage.
- The readiness probe sends `Host: localhost` (see issue #4). `localhost` is in `ALLOWED_HOSTS` only for this purpose.

---

## 6. Phase 2: Helm chart

### 6.1 Converting manifests to templates
The kubectl-created resources were deleted (Helm can't adopt resources it didn't create, see issue #8), and every manifest became a template:

| Template | Values used |
|---|---|
| `configmap.yaml` | Loops over `.Values.config` with `range`. `quote` keeps every value a string |
| `secrets.yaml` | Loops over `.Values.secrets` with `b64enc \| quote` (plain values in, base64 out) |
| `deployment.yaml` | `replicaCount`, `image.repository/tag`, `containerPort`, `resources` (`toYaml \| nindent 12`) |
| `service.yaml` | `service.type`, `service.port`, `targetPort: http` (the named container port) |
| `ingress.yaml` | `ingress.className`, `ingress.host`, `ingress.clusterIssuer` |
| `cluster-issuer.yaml` | `letsencrypt.email`, `ingress.className` |
| `hpa.yaml` | `autoscaling.minReplicas/maxReplicas/target*UtilizationPercentage` |

All resource names come from `{{ .Release.Name }}`, so references between them (Deployment → ConfigMap/Secret, Service → pods, HPA → Deployment, Ingress → Service) always match. The release must be installed as **`healthchecks`**.

Every template was checked with `helm lint` and `helm template ... -s templates/<file>.yaml` before applying.

### 6.2 How the requirements map to the chart

| Requirement | Implementation |
|---|---|
| ConfigMap for env vars | `templates/configmap.yaml` ← `values.yaml: config` |
| Secret, encrypted | `templates/secrets.yaml` ← `secrets-values.yaml` (sops/age, see §7) |
| 2 replicas | `replicaCount: 2`, `autoscaling.minReplicas: 2` |
| Port 8080 | `containerPort: 8080`, image runs `gunicorn --bind 0.0.0.0:8080` |
| ConfigMap + Secret propagated | `envFrom: configMapRef + secretRef` on the app and the migrate container |
| Readiness + liveness probes | HTTP `/api/v3/status/` + TCP `:8080` |
| Service ClusterIP | `service.type: ClusterIP` |
| Ingress controller that provisions an LB | ingress-nginx (helmfile) → `LoadBalancer` Service → AWS NLB |
| cert-manager + Let's Encrypt | cert-manager (helmfile) + `letsencrypt-prod` ClusterIssuer + Ingress annotation |
| HPA 2→4 at 80% CPU or RAM | `hpa.yaml`, two `Resource` metrics at `averageUtilization: 80` |

### 6.3 helmfile (`helmfile/helmfile.yaml`)
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
- **`needs`** ensures the IngressClass and cert-manager CRDs/webhook exist before the app's Ingress and ClusterIssuer are created.
- **`wait: true`** prevents `failed calling webhook "webhook.cert-manager.io"`, which would happen if the ClusterIssuer were created before cert-manager's webhook was ready.
- metrics-server isn't in the helmfile, because EKS installs it as a default add-on (issue #15).

The day-to-day workflow is **edit → `helmfile diff` → `helmfile apply`**. It was tested by adding `SITE_NAME`: the diff showed exactly one ConfigMap line, and `apply` created a new Helm revision.

---

## 7. Secret encryption (helm-secrets + sops + age)

| Tool | Role |
|---|---|
| **age** | Key pair: the public key encrypts, the private key decrypts |
| **sops** | Encrypts YAML **values** and leaves the keys readable, so diffs show *which* secret changed but not its value |
| **helm-secrets** | Decrypts the file in memory at deploy time and passes it to Helm |

### Setup
```bash
brew install sops age
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt          # private key, never committed, backed up
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"   # added to ~/.zshrc
```

`.sops.yaml` (committed, contains only the **public** key):
```yaml
creation_rules:
  - path_regex: secrets-values.*\.yaml$
    age: age1wnkuvknr5sj4acjt3fxuugc902zhd9p849vghnzjnajn45yxuupsen9xpk
```
The regex is deliberately narrow so it can't match `templates/secrets.yaml`.

### Workflow
```bash
sops -e -i helm_chart/secrets-values.yaml     # encrypt in place (once)
sops helm_chart/secrets-values.yaml           # edit: decrypts in $EDITOR, re-encrypts on save
helm secrets template ... -f helm_chart/secrets-values.yaml   # render with decryption
```
helmfile decrypts it automatically through the `secrets:` key. `.gitignore` contains `*.dec`, because helm-secrets briefly writes a decrypted `.dec` copy during rendering.

The encrypted file looks like this in git:
```yaml
secrets:
    SECRET_KEY: ENC[AES256_GCM,data:...,type:str]
    DB_PASSWORD: ENC[AES256_GCM,data:...,type:str]
sops:
    age: [...]
```

---

## 8. Phase 3: Deployment to AWS

### 8.1 Cloud choice
DigitalOcean was the first choice, but it required a $10 payment to verify the account. AWS was used instead. EKS also allows the cluster and RDS to share **one VPC**, so database traffic never leaves the private network.

### 8.2 EKS cluster (`infra/eks-cluster.yaml`)
```yaml
metadata: { name: healthchecks, region: us-east-1 }
vpc:
  nat: { gateway: Disable }          # saves ~$1/day
managedNodeGroups:
  - name: default
    instanceType: t3.small           # amd64 → image tag v1.4
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    privateNetworking: false         # nodes in public subnets, so they pull images without a NAT
```
```bash
eksctl create cluster -f infra/eks-cluster.yaml --dry-run   # review the config first
eksctl create cluster -f infra/eks-cluster.yaml             # ~15–20 min, Kubernetes 1.34
```
eksctl created the VPC (2 AZs, public and private subnets), the control plane, 2 nodes, and the default add-ons `vpc-cni`, `kube-proxy`, `coredns` and **`metrics-server`**.

### 8.3 RDS (created while the control plane was still being built)
As soon as the VPC appeared (a few minutes into `eksctl create`), RDS was created in its **private** subnets:

```bash
aws rds create-db-subnet-group --db-subnet-group-name healthchecks-db \
  --db-subnet-group-description "Private subnets of the healthchecks EKS VPC" \
  --subnet-ids <private-subnet-a> <private-subnet-b>

SG=$(aws ec2 create-security-group --group-name healthchecks-db \
  --description "Postgres access from inside the EKS VPC" \
  --vpc-id <eksctl-vpc-id> --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG \
  --protocol tcp --port 5432 --cidr 192.168.0.0/16            # VPC only

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
- The RDS endpoint was then set as `config.DB_HOST` in `values.yaml`, along with `DB_SSLMODE: "require"`.

### 8.4 Chart values for AWS
`helm_chart/values.yaml` holds the production values: `image.tag: v1.4`, `ingress.host: hc.vadymthebest.com`, `ingress.clusterIssuer: letsencrypt-prod`, `ingress.className: nginx`, and matching `SITE_ROOT` and `ALLOWED_HOSTS`. Before deploying, everything was rendered with:
```bash
helmfile -f helmfile/helmfile.yaml template --selector name=healthchecks
```
This caught a wrong `ALLOWED_HOSTS` value (issue #13).

### 8.5 Deploy
```bash
kubectl config current-context                 # always confirm the target cluster
helmfile -f helmfile/helmfile.yaml sync        # first install (see issue #17)
```
Result: ingress-nginx, cert-manager and healthchecks were deployed. The `migrate` init container applied all migrations **on RDS**, both app pods reached `1/1`, and AWS created the NLB.

### 8.6 DNS and certificate
1. The NLB hostname was taken from `kubectl get svc -n ingress-nginx ingress-nginx-controller`.
2. In Namecheap (cPanel → Zone Editor), a **CNAME** `hc` → `<nlb-hostname>` was added with TTL 300. A CNAME rather than an A record, because an NLB has a DNS name and AWS can change the IPs behind it.
3. cert-manager's HTTP-01 challenge completed after DNS propagated (see issue #18 for a delay), and the Certificate became `READY True`.

---

## 9. Verification

| Check | Result |
|---|---|
| `curl https://hc.vadymthebest.com/api/v3/status/` | `OK` (app → RDS works over a trusted TLS connection) |
| Certificate | Issuer **Let's Encrypt**, subject `hc.vadymthebest.com`, valid 90 days, auto-renewed by cert-manager |
| `http://hc.vadymthebest.com/` | `308` redirect to HTTPS (added by ingress-nginx because the Ingress has TLS) |
| Browser | Padlock + Healthchecks login page |
| `kubectl get hpa` | `cpu: x%/80%, memory: x%/80%`, min 2 / max 4 |
| HPA under load (busybox `wget` loop against the Service) | Scaled 2 → 4 replicas |
| `helm list -A` | 3 releases deployed by helmfile |

Screenshots are attached separately.

---

## 10. Teardown

The order matters. Deleting the cluster first would leave the NLB running (only Kubernetes knows about it), and the RDS security group would block VPC deletion.

```bash
# 1. Releases first → the LoadBalancer Service is removed → AWS deletes the NLB
helmfile -f helmfile/helmfile.yaml destroy
aws elbv2 describe-load-balancers          # must be empty

# 2. RDS and its network objects (they live inside the eksctl VPC)
aws rds delete-db-instance --db-instance-identifier healthchecks-db \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier healthchecks-db
aws rds delete-db-subnet-group --db-subnet-group-name healthchecks-db
aws ec2 delete-security-group --group-id <rds-sg-id>

# 3. Cluster + VPC
eksctl delete cluster -f infra/eks-cluster.yaml --wait

# 4. Remove the DNS CNAME (it would otherwise point at a load balancer that no longer exists)
```
Afterwards it was verified that nothing billable remained in us-east-1: no EKS clusters, CloudFormation stacks, EC2 instances, VPC, load balancers, unattached EBS volumes, Elastic IPs, NAT gateways, RDS instances or snapshots, or CloudWatch log groups.

**Cost:** the AWS environment existed for about 1.5 hours (EKS control plane, 2 × t3.small, NLB, db.t4g.micro), for a total well under $1.

---

## 11. Issues faced and solutions

### Image and build

**#1. Image didn't run on minikube (Apple Silicon).**
*Symptom:* `no matching manifest for linux/arm64/v8 in the manifest list entries`.
*Cause:* the image was built only for amd64, and minikube on an M-series Mac runs arm64 nodes.
*Solution:* built an arm64 variant (`v1.5`) for local use and kept amd64 (`v1.4`) for EKS. A single multi-arch tag (`docker buildx imagetools create`) would avoid switching tags between environments.

**#2. App listened on port 8000, but the task requires 8080.**
*Solution:* changed the Dockerfile to `EXPOSE 8080` and `CMD ["gunicorn", "hc.wsgi:application", "--bind", "0.0.0.0:8080"]`. `GUNICORN_CMD_ARGS` doesn't help here, because a `--bind` on the command line takes precedence over it.

### Secrets

**#3. `SECRET_KEY` silently became binary garbage.**
*Cause:* the output of `openssl rand -base64 48` was pasted directly under `data:`. It's valid base64, so `kubectl apply` accepted it, but Kubernetes *decodes* `data:` values, so the app would have received 48 random bytes instead of the string.
*Solution:* encode the string once more (`echo -n '<key>' | base64`), or use `stringData:`. Lesson: values under `data:` are the base64 of what the app should see. `echo -n` matters, because a trailing newline ends up in the value.

**#9. Helm install: `password authentication failed for user "hc"`.**
*Cause:* `secrets-values.yaml` contained the **already base64-encoded** values copied from the old manifest, and the template's `b64enc` encoded them again. This was confirmed by comparing lengths: the password was 20 characters instead of 14 (exactly the base64 length of 14 bytes).
*Solution:* `sops helm_chart/secrets-values.yaml` → replace the values with plain text → `helm secrets upgrade`. Rule: values files hold plain text, and the template does the encoding.

**#10. Installing helm-secrets on Helm 4.**
*Symptom:* most tutorials show `helm plugin install https://github.com/jkroepke/helm-secrets`, which is the Helm 3 method.
*Solution:* on Helm 4, helm-secrets is split into three plugins (`secrets`, `secrets-getter`, `secrets-post-renderer`) installed from release `.tgz` files.

**#11. Helm 4 plugin signature verification failed.**
*Symptom:* `plugin verification failed: open ~/.gnupg/pubring.gpg: no such file or directory`.
*Cause:* Helm 4 verifies plugin signatures by default and needs a binary GPG keyring with the author's public key.
*Solution:* `curl -sL https://github.com/jkroepke.gpg | gpg --dearmor > ~/.config/helm/jkroepke.gpg`, then `helm plugin install --keyring ~/.config/helm/jkroepke.gpg <url>`. Verification was kept on instead of using `--verify=false`.
*Note:* `helmfile init` installed helm-diff **without** signature verification ("Skipping plugin signature verification").

**#12. sops couldn't decrypt in non-interactive shells.**
*Symptom:* `Failed to get the data key required to decrypt the SOPS file ... Did not find keys in locations ... SOPS_AGE_KEY_FILE`.
*Cause:* the key path is set in `~/.zshrc`, which isn't loaded by every shell (scripts, IDE terminals, CI). On macOS, sops' default key location is `~/Library/Application Support/sops/age/keys.txt`, not `~/.config/...`.
*Solution:* make sure `SOPS_AGE_KEY_FILE` is set wherever helm-secrets runs.

### Probes, scaling and configuration

**#4. Readiness probe failed with HTTP 400.**
*Cause:* kubelet sends probes with `Host: <pod-IP>`, which isn't in Django's `ALLOWED_HOSTS`, so Django answers `400 DisallowedHost`. This was reproduced on purpose: `Readiness probe failed: HTTP probe failed with statuscode: 400`.
*Solution:* add `httpHeaders: [{name: Host, value: localhost}]` to the probe, and `localhost` to `ALLOWED_HOSTS`. The probe goes directly to the pod IP (not through DNS or the Ingress), so `localhost` works in every environment.

**#5. Readiness probe passed without ever checking the database.**
*Cause:* the path was `/api/v3/status` (no trailing slash). Django redirects it with `301`, and Kubernetes treats any 2xx–3xx response as success.
*Solution:* use `/api/v3/status/`. Confirmed with `curl -si ... | head -1` → `301` vs `200`.

**#6. HPA never scaled back down after the load test.**
*Symptom:* 96 minutes after the load stopped: `cpu: 2%/80%, memory: 65%/80%`, still 4 replicas.
*Cause:* HPA formula `desired = ceil(current × usage / target) = ceil(4 × 65 / 80) = 4`. The idle memory of a gunicorn pod (~83Mi) was already 65% of the 128Mi request, and Python processes don't release memory.
*Solution:* set the memory request to a realistic `256Mi` (idle ≈ 32%). Afterwards the HPA showed `memory: 31%/80%` and could scale down to 2.

**#7. ConfigMap changes didn't reach running pods.**
*Cause:* env vars are read only when a container starts.
*Solution:* `kubectl rollout restart deployment healthchecks` after config changes. (A `checksum/config` pod annotation would automate this, but it isn't part of the task.)

**#14. Possible first-deploy race in migrations.**
Both replicas run `manage.py migrate` in their init containers at the same time. On a brand-new database one of them may fail once and restart. This didn't happen in the final deploy, but it's a known limitation of the initContainer approach (see §12).

### Helm and helmfile

**#8. Helm couldn't take over resources created with `kubectl apply`.**
*Solution:* deleted the kubectl-created Deployment, Service, Ingress, HPA, ConfigMap and Secret, then installed them through Helm. Postgres, the issuer and cert-manager were kept, because they aren't part of the chart.

**#13. Wrong `ALLOWED_HOSTS` caught before deploy.**
`ALLOWED_HOSTS` was set to `vadymthebest.com` instead of `hc.vadymthebest.com`, which would have made Django answer 400 to every request. It was caught by rendering the chart (`helmfile template ... | grep ALLOWED_HOSTS`) before creating any cloud resources. `ingress.host`, `SITE_ROOT` and `ALLOWED_HOSTS` must always match.

**#16. `Chart.yaml` accidentally overwritten with an empty file.**
*Symptom:* `helm lint`: `Chart.yaml: name is required ... unable to load chart`.
*Solution:* restored the content. The repo had no commits yet, so git couldn't help. Lesson: commit after every working step.

**#17. First `helmfile apply` failed at the diff stage.**
*Symptom:* `error validating data: the server is currently unable to handle the request` for the healthchecks release.
*Cause:* (a) the metrics-server API had just started and was briefly unavailable, and (b) helm-diff validates the chart against the live cluster, but the chart contains a `ClusterIssuer`, whose CRD didn't exist until cert-manager was installed.
*Solution:* `helmfile sync` for the first install (installs in `needs` order without a diff). Every later change uses `diff`/`apply` normally.

### AWS

**#15. metrics-server conflict on EKS.**
eksctl 0.231 installs `metrics-server` as a default EKS add-on (`default addons metrics-server, vpc-cni, kube-proxy, coredns ... will install them as EKS addons`). The metrics-server release was removed from the helmfile, because it would have conflicted with the add-on's resources.

**#19. RDS subnet group creation: "Some input subnets ... are invalid".**
*Cause:* the shell had `AWS_DEFAULT_REGION=eu-central-1` set, which **overrides** `~/.aws/config` (us-east-1). RDS looked for the us-east-1 subnets in Frankfurt. eksctl wasn't affected, because the region is set explicitly in `infra/eks-cluster.yaml`.
*Solution:* `export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1` (or `--region us-east-1`). Check `aws configure list` to see which region applies and where it comes from.

**#18. Let's Encrypt certificate stuck in `pending` after DNS had propagated.**
*Symptom:* `Waiting for HTTP-01 challenge propagation: failed to perform self check ... lookup hc.vadymthebest.com on 10.100.0.10:53: no such host`, although public DNS checkers already showed the CNAME.
*Cause:* cert-manager's self-check ran **before** the DNS record existed, and the cluster's resolver cached the `NXDOMAIN` answer. The domain's SOA allows negative caching for 3601 seconds.
*Solution:* waited for the negative cache to expire (it cleared within minutes). cert-manager then validated the challenge and issued the certificate. No Let's Encrypt rate limit was used, because the self-check only contacts Let's Encrypt after it passes. Lesson: create the DNS record before the certificate is requested, or use cert-manager's `waitInsteadOfSelfCheck` option.

### Choices and setbacks

**#20. DigitalOcean account verification.** It required a $10 prepayment, so the project switched to AWS (§8.1).

**#21. Choosing the ingress controller on AWS.**
- **AWS Load Balancer Controller (ALB)** was rejected: an ALB only serves certificates from AWS ACM and can't use the Let's Encrypt certificate that cert-manager stores in a Kubernetes Secret. That would make the cert-manager requirement pointless. It also needs IAM/OIDC setup.
- **ingress-nginx** was chosen: it terminates TLS with the cert-manager Secret, and its `LoadBalancer` Service makes AWS create an **NLB** (`aws-load-balancer-type: nlb`). Note that the upstream ingress-nginx project has been retired (maintenance ended in March 2026). For a long-lived deployment, a maintained controller such as Traefik would be the better choice.

**#22. Dangling DNS record after teardown.** The CNAME still pointed at the deleted NLB. It was removed to avoid a potential subdomain-takeover risk.

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
| Release in the `default` namespace | Simplicity | A dedicated namespace (`--create-namespace` / helmfile `namespace:`) |
| ingress-nginx | Familiar from minikube, works with cert-manager | A maintained controller (e.g. Traefik), since ingress-nginx is retired |
| Healthchecks `sendalerts` worker not deployed | Outside the assignment scope | A second Deployment running `manage.py sendalerts` |

### Running locally again
`values.yaml` now contains the AWS settings. To run on minikube again, deploy `local/postgres.yaml` and `local/selfsigned-issuer.yaml`, then override the AWS-specific values:
```bash
helm secrets install healthchecks ./helm_chart -f helm_chart/secrets-values.yaml \
  --set image.tag=v1.5 \
  --set ingress.host=healthchecks.local --set ingress.clusterIssuer=selfsigned \
  --set config.DB_HOST=postgres --set config.DB_SSLMODE=prefer \
  --set config.SITE_ROOT=https://healthchecks.local \
  --set config.ALLOWED_HOSTS='healthchecks.local\,localhost'
```

---

## 13. Values to replace for your own deployment

The repository contains the values used for this deployment (domain `vadymthebest.com`, region `us-east-1`, a specific RDS endpoint, and so on). To deploy it into another account or with another domain, replace the values below. Everything marked **must** is environment-specific and won't work as-is.

### 13.1 `helm_chart/values.yaml`

| Key | Current value | Replace with | Notes |
|---|---|---|---|
| `config.DB_HOST` | `healthchecks-db.cwv2a4uw41qv.us-east-1.rds.amazonaws.com` | **must:** your RDS endpoint | `aws rds describe-db-instances --db-instance-identifier <id> --query 'DBInstances[0].Endpoint.Address' --output text`. This RDS instance no longer exists. |
| `config.DB_NAME` | `hc` | the RDS `--db-name` | Must match what RDS was created with |
| `config.DB_USER` | `hc` | the RDS `--master-username` | Must match what RDS was created with |
| `config.DB_PORT` | `5432` | usually unchanged | |
| `config.DB_SSLMODE` | `require` | `require` for RDS; `prefer` for the local Postgres | |
| `config.SITE_ROOT` | `https://hc.vadymthebest.com` | **must:** `https://<your-host>` | Must match `ingress.host` |
| `config.ALLOWED_HOSTS` | `hc.vadymthebest.com,localhost` | **must:** `<your-host>,localhost` | Keep `localhost`, because the readiness probe uses it. A mismatch makes Django answer `400` |
| `ingress.host` | `hc.vadymthebest.com` | **must:** your domain/subdomain | You must control its DNS (needed for Let's Encrypt) |
| `ingress.className` | `nginx` | the IngressClass of your controller | e.g. `traefik` if you switch controllers |
| `ingress.clusterIssuer` | `letsencrypt-prod` | usually unchanged | `selfsigned` on minikube (with `local/selfsigned-issuer.yaml`) |
| `letsencrypt.email` | the author's email | **must:** your email | Receives Let's Encrypt expiry warnings |
| `image.repository` | `melnykv2/healthchecks` | your image, if you build your own | |
| `image.tag` | `v1.4` (amd64) | the tag matching your **node CPU architecture** | `v1.5` = arm64 (e.g. minikube on Apple Silicon). Wrong arch → `ErrImagePull` / `exec format error` |
| `resources`, `replicaCount`, `autoscaling.*` | 100m/256Mi, 2, 2–4 @ 80% | optional tuning | Keep the memory request above the app's idle usage (see issue #6) |

**Keep these three in sync:** `ingress.host`, `config.SITE_ROOT` and `config.ALLOWED_HOSTS`. Check them before deploying:
```bash
helmfile -f helmfile/helmfile.yaml template --selector name=healthchecks \
  | grep -E "image:|host:|DB_HOST|SITE_ROOT|ALLOWED_HOSTS|cluster-issuer"
```

### 13.2 Secrets: `helm_chart/secrets-values.yaml` and `.sops.yaml`

The committed file is encrypted for **the author's age key**. Nobody else can decrypt it, so a new deployer creates their own:

```bash
# 1. Your own age key
age-keygen -o ~/.config/sops/age/keys.txt         # prints "Public key: age1..."
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# 2. Put YOUR public key into .sops.yaml
#    creation_rules[0].age: age1<your-public-key>

# 3. Write the secrets in PLAIN text (the template base64-encodes them)
cat > helm_chart/secrets-values.yaml <<'YAML'
secrets:
  SECRET_KEY: "<output of: openssl rand -base64 48>"
  DB_PASSWORD: "<your RDS master password>"
YAML

# 4. Encrypt in place before committing
sops -e -i helm_chart/secrets-values.yaml
```

| Key | Notes |
|---|---|
| `SECRET_KEY` | A long random string. Django uses it to sign sessions and tokens. Never reuse the example |
| `DB_PASSWORD` | **Must be identical** to the RDS master password. Easiest: create RDS with `--master-user-password "$(sops -d --extract '["secrets"]["DB_PASSWORD"]' helm_chart/secrets-values.yaml)"` (§8.3). RDS forbids `/`, `"`, `@` and spaces. Plain text only, never pre-base64-encoded (issue #9) |

### 13.3 `infra/eks-cluster.yaml`

| Key | Current value | Notes |
|---|---|---|
| `metadata.name` | `healthchecks` | Cluster name. Must be unique in the region |
| `metadata.region` | `us-east-1` | Your region. RDS must be created in the **same** region and VPC |
| `managedNodeGroups[].instanceType` | `t3.small` (amd64) | If you pick a Graviton type (`t4g.*`, arm64), switch `image.tag` to the arm64 image |
| `desiredCapacity` / `minSize` / `maxSize` | `2` | Node count |

### 13.4 RDS creation commands (§8.3)

These IDs are created by eksctl and differ in every deployment. Look them up after the VPC exists:

| Placeholder | How to find it |
|---|---|
| `<eksctl-vpc-id>` | `aws ec2 describe-vpcs --filters Name=tag:alpha.eksctl.io/cluster-name,Values=<cluster-name> --query 'Vpcs[0].VpcId' --output text` |
| `<private-subnet-a/b>` | `aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> Name=map-public-ip-on-launch,Values=false --query 'Subnets[].SubnetId' --output text` |
| VPC CIDR (`192.168.0.0/16`) | eksctl's default. Check with `describe-vpcs --query 'Vpcs[0].CidrBlock'` |
| `--db-instance-class` | `db.t4g.micro`. Pick another class if it isn't offered in your region/AZ |

### 13.5 `helmfile/helmfile.yaml`

| Key | Notes |
|---|---|
| `releases[].version` | Pinned chart versions (`ingress-nginx 4.15.1`, `cert-manager v1.21.2`). Update deliberately, checking `helm search repo <chart>` |
| `healthchecks.namespace` | `default`. Change it to use a dedicated namespace (`helmDefaults.createNamespace` creates it) |
| ingress-nginx `service.beta.kubernetes.io/aws-load-balancer-type` | `nlb` is AWS-specific. On another provider, use its load balancer annotations instead |

### 13.6 Outside the repository

| What | Where | Value |
|---|---|---|
| DNS record | Your DNS provider | `CNAME <subdomain>` → the ingress-nginx load balancer hostname from `kubectl get svc -n ingress-nginx ingress-nginx-controller`. Add it **before** or right after the first deploy (see issue #18) |
| `SOPS_AGE_KEY_FILE` | Shell profile / CI secrets | Path to your age private key, wherever helm-secrets runs |
| AWS region | `AWS_REGION` / `AWS_DEFAULT_REGION` / `~/.aws/config` | Must match `metadata.region`. Environment variables override the config file (issue #19) |
| kube context | `kubectl config current-context` | Must point at the target cluster before `helmfile sync/apply` |
