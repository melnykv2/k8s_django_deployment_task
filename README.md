# k8s_django_deployment_task

Deploys the **Healthchecks** Django application (`melnykv2/healthchecks`) to **AWS EKS** with Helm and helmfile. The database runs in **Amazon RDS (PostgreSQL)**. HTTPS uses a **Let's Encrypt** certificate issued by cert-manager.

**Live during testing:** `https://hc.vadymthebest.com`. The environment has since been torn down to avoid costs.

## Repository structure

```
├── helm_chart/                    # Application chart
│   ├── Chart.yaml
│   ├── values.yaml                # All non-secret settings (image, domain, RDS host, HPA, ...)
│   ├── secrets-values.yaml        # Secret values, encrypted with sops + age (helm-secrets)
│   └── templates/
│       ├── configmap.yaml         # Non-secret env vars
│       ├── secrets.yaml           # Secret env vars (DB password, Django SECRET_KEY)
│       ├── deployment.yaml        # 2 replicas, port 8080, envFrom, probes, migrate initContainer
│       ├── service.yaml           # ClusterIP
│       ├── ingress.yaml           # ingress-nginx + TLS via cert-manager
│       ├── cluster-issuer.yaml    # Let's Encrypt (prod) ClusterIssuer
│       └── hpa.yaml               # 2–4 replicas at 80% CPU / memory
├── helmfile/helmfile.yaml         # Whole environment: ingress-nginx, cert-manager, app
├── infra/eks-cluster.yaml         # eksctl cluster definition
├── local/                         # Minikube-only helpers (in-cluster Postgres, self-signed issuer)
├── .sops.yaml                     # sops rule: which file is encrypted, with which age key
└── documentation/deployment_guide.md
```

## Quick start

Prerequisites: `kubectl`, `helm` (v4), `helmfile`, the helm-secrets and helm-diff plugins, `sops`, `age`, `eksctl` and the `aws` CLI. You also need the age private key that `secrets-values.yaml` was encrypted with.

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

eksctl create cluster -f infra/eks-cluster.yaml          # ~15–20 min
# create RDS in the cluster VPC and set config.DB_HOST in helm_chart/values.yaml (see guide §8.3)

helmfile -f helmfile/helmfile.yaml sync                   # first install
helmfile -f helmfile/helmfile.yaml apply                  # every later change
```

Then point a DNS CNAME for the host in `ingress.host` at the ingress-nginx load balancer.

> **Before deploying in your own account, replace the environment-specific values.** These include `config.DB_HOST` (RDS endpoint), the domain (`ingress.host`, `SITE_ROOT`, `ALLOWED_HOSTS`), `letsencrypt.email`, `image.tag` (must match the node CPU architecture), the age public key in `.sops.yaml`, and your own encrypted `secrets-values.yaml`. The full list is in **[guide §13](documentation/deployment_guide.md#13-values-to-replace-for-your-own-deployment)**.

See **[documentation/deployment_guide.md](documentation/deployment_guide.md)** for every step, the issues faced and their solutions, and why Kubernetes and Helm fit this scenario.
