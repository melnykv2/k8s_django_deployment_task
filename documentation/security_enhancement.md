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

## 4. RBAC for users (threats #5, #6)

`templates/rbac.yaml` (added to the given structure) gives three groups access to the `healthchecks` namespace only:

| Group | Binding | Can | Cannot |
|---|---|---|---|
| `healthchecks:viewers` | Role `viewer` | read pods, logs, deployments, services, ingresses, network policies | read Secrets, change anything |
| `healthchecks:developers` | Role `developer` | viewer + delete (restart) pods, scale the Deployment | read Secrets, `exec`, edit the pod template |
| `healthchecks:admins` | ClusterRole `admin` via a **Role**Binding | everything in the namespace | anything outside it |

- **No Secrets** for viewers and developers: the DB password and Django key stay with admins.
- **No pod-template editing** for developers: whoever can change the pod spec can mount any Secret and print it.
- **Groups, not users:** people are mapped to groups through EKS access entries (IAM role → Kubernetes group), so access changes happen in IAM, not in the chart.

## 5. Tests for the Helm templates

**Connection test** (`templates/tests/test-connection.yaml`, run with `helm test`): after deployment, a hardened busybox pod calls `/api/v3/status/` through the Service. It has its own NetworkPolicy (`helm-test`), so it also proves the policies allow the required traffic.

**Unit tests** (`k8s_security_enhancement/tests/*_test.yaml`, [helm-unittest](https://github.com/helm-unittest/helm-unittest)) render the templates without a cluster and check the security settings, so removing or breaking one fails the tests:

| Suite | Checks |
|---|---|
| `deployment_test.yaml` | namespace, non-root, seccomp, no privilege escalation, read-only filesystem, capabilities dropped (app and initContainer), no API token |
| `networkpolicy_test.yaml` | 4 policies, default deny, ingress only on 8080, metadata service blocked, ACME solver allowed |
| `rbac_test.yaml` | no Secrets for viewers and developers, no exec for developers, admins limited to the namespace |

```
vadymmelnyk@Macbook k8s_django_deployment_task % helm unittest k8s_security_enhancement

### Chart [ django-app ] k8s_security_enhancement

 PASS  deployment security    k8s_security_enhancement/tests/deployment_test.yaml
 PASS  network policies    k8s_security_enhancement/tests/networkpolicy_test.yaml
 PASS  RBAC    k8s_security_enhancement/tests/rbac_test.yaml

Charts:      1 passed, 1 total
Test Suites: 3 passed, 3 total
Tests:       13 passed, 13 total
Snapshot:    0 passed, 0 total
Time:        33.587125ms
```

## 6. Repository structure

```
├── k8s_security_enhancement
│   ├── charts/
│   ├── Chart.yaml
│   ├── .helmignore
│   ├── templates/
│   │   ├── _helpers.tpl
│   │   ├── ns.yaml
│   │   ├── serviceaccount.yaml
│   │   ├── deployment.yaml
│   │   ├── networkpolicy.yaml
│   │   ├── rbac.yaml                 
│   │   ├── configmap.yaml, 
|   |   |--secret.yaml 
|   |   |-- service.yaml
|   |   |-- ingress.yaml
|   |   |-- hpa.yaml
|   |   |-- issuer.yaml
│   │   └── tests/test-connection.yaml
│   ├── tests/
│   └── values.yaml
├── helmfile.yaml
└── helm_secrets/
    ├── django_config.yaml
    ├── django_secret.yaml
    └── .sops.yaml
```
