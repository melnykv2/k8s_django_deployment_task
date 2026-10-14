# k8s_django_deployment_task

Deploys a Django application to **DigitalOcean Kubernetes** with Helm and helmfile.

- `helm_chart/`: application chart with a ConfigMap, an encrypted Secret (helm-secrets/sops), a Deployment (2 replicas, port 8080, probes), a ClusterIP Service, an Ingress (Traefik → DigitalOcean LB), cert-manager Let's Encrypt ClusterIssuers, an HPA (2–4 replicas at 80% CPU/RAM), and a migrations Job.
- `helmfile/helmfile.yaml`: the whole environment (metrics-server, Traefik, cert-manager, django-app).
- `documentation/deployment_guide.md`: step-by-step guide, issues and solutions, and why Kubernetes and Helm.

## Quick start

```bash
# one-time: create the secrets file from the template and encrypt it (see guide §7)
cp helmfile/secrets/django-app.secrets.yaml.example helmfile/secrets/django-app.secrets.yaml
helm secrets encrypt -i helmfile/secrets/django-app.secrets.yaml

helmfile -f helmfile/helmfile.yaml deps
helmfile -f helmfile/helmfile.yaml apply
```

Before deploying, replace the placeholder values (`example.com`, `my-registry`, DB host, age public key in `.sops.yaml`).
