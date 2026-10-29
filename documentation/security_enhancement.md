# Kubernetes Security Enhancement

## 1. Threat assessment

**Scope:**
- the Helm chart (`k8s_security_enhancement/`)
- the vendored subcharts
- `helmfile.yaml`
- the EKS cluster definition (`infra/eks-cluster.yaml`)

**Scenario:** an attacker finds a bug in Django and can run commands inside an application pod. How far can they get?

| # | Threat | Where (evidence) | Severity | Mitigation | Step |
|---|---|---|---|---|---|
| 1 | A compromised container can gain privileges, use Linux capabilities and write to its filesystem | `deployment.yaml` has no `securityContext` | High | `securityContext`: non-root, no privilege escalation, read-only filesystem, drop all capabilities, seccomp | 2 |
| 2 | Anyone who can create pods can start a privileged pod and take over the node | App runs in `default`, no Pod Security Admission | High | Dedicated namespace with Pod Security `restricted` | 2 |
| 3 | Every pod gets a Kubernetes API token it never uses | No `automountServiceAccountToken: false` | Medium | Dedicated ServiceAccount without a token | 2 |
| 4 | Any pod can reach any other pod and the AWS metadata service (node IAM credentials) | No NetworkPolicy | High | Default deny + allow only ingress-nginx → app, app → DNS and database | 3 |
| 5 | One identity is admin of everything; no limited access is possible | Only the cluster creator has access | High | RBAC roles: viewer, developer, namespace admin | 4 |
| 6 | Anyone allowed to read Secrets sees the DB password (base64 is not encryption) | `secret.yaml` | Medium | RBAC: viewers and developers cannot read Secrets | 4 |
| 7 | ingress-nginx 4.8.1 is vulnerable to CVE-2025-1974 "IngressNightmare" (read all cluster Secrets); the project no longer receives fixes since March 2026. cert-manager v1.13 is end of life | `charts/ingress-nginx-4.8.1.tgz`, `charts/cert-manager-v1.13.1.tgz` | High | Disable the ingress-nginx admission webhook now; upgrade the components | 2 + proposal |
| 8 | Long-lived AWS access keys stored in plain text on the workstation | `~/.zshrc` | High | Rotate keys, use AWS SSO with short-lived credentials | Proposal |

**Already good:**
- secrets encrypted in Git with sops + age
- HTTPS with Let's Encrypt
- the image runs as a non-root user (`USER 1000`)
- RDS is not publicly accessible, and the app connects over SSL
- resource requests and limits are set

## 2. Pod-level hardening

### 2.1 securityContext (threat #1)

Set in `values.yaml` (`podSecurityContext`, `containerSecurityContext`) and applied in `deployment.yaml` to the app container **and** the `migrate` initContainer:

| Setting | Why |
|---|---|
| `runAsNonRoot: true`, `runAsUser: 1000` | The container can never start as root |
| `allowPrivilegeEscalation: false` | A process cannot gain more rights (e.g. via setuid binaries) |
| `capabilities: drop: ["ALL"]` | No Linux capabilities: much less kernel attack surface |
| `readOnlyRootFilesystem: true` | An attacker cannot drop tools or change code; `/tmp` is a small `emptyDir` |
| `seccompProfile: RuntimeDefault` | Dangerous system calls are blocked |

### 2.2 Namespaces and Pod Security Admission (threat #2)

`securityContext` protects our pods. Pod Security Admission makes the API server **reject any unsafe pod** in a namespace, whoever creates it. It is enabled with namespace labels:

| Namespace | Created by | Pod Security | Why |
|---|---|---|---|
| `healthchecks` (app) | `templates/ns.yaml` | `restricted` | Strictest level; the app complies |
| `cert-manager` | `templates/ns.yaml` | `restricted` | cert-manager v1.13 complies |
| `ingress-nginx` (release namespace) | helmfile `presync` hook | `baseline` (audit `restricted`) | The 4.8.1 controller needs privilege escalation to bind ports 80/443 |

The Helm release lives in `ingress-nginx` because the ingress-nginx 4.8.1 subchart can only be installed into the release namespace. cert-manager is moved with its `namespace` value. Nothing runs in `default`.

The ingress-nginx admission webhook is disabled (`controller.admissionWebhooks.enabled: false`), the published workaround for CVE-2025-1974 (threat #7).

### 2.3 ServiceAccount without an API token (threat #3)

`templates/serviceaccount.yaml` creates a dedicated `healthchecks` ServiceAccount with `automountServiceAccountToken: false`. The pod uses it and repeats the setting. The app never calls the Kubernetes API, so a compromised pod has no token to explore the cluster with.

## 3. Network policies (threat #4)

By default every pod can reach every pod and the internet. `templates/networkpolicy.yaml` (added to the given structure) creates three policies in `healthchecks`:

| Policy | Pods | Allowed |
|---|---|---|
| `default-deny-all` | all | nothing |
| app | `app: <release>` | **in:** TCP 8080 from `ingress-nginx` · **out:** DNS to CoreDNS, TCP 5432 to the VPC (RDS), TCP 443 to the internet **except** private ranges and `169.254.0.0/16` |
| `acme-http01-solver` | cert-manager solver pods | **in:** TCP 8089 from `ingress-nginx` (Let's Encrypt validation) |

Blocking `169.254.0.0/16` stops a compromised pod from reading the node's AWS credentials from the EC2 metadata service.

EKS ignores NetworkPolicies unless the VPC CNI enforces them, so `infra/eks-cluster.yaml` enables it:

```yaml
addons:
  - name: vpc-cni
    configurationValues: '{"enableNetworkPolicy": "true"}'
```
