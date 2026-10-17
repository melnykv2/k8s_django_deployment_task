# Deployment Guide: Healthchecks on AWS EKS

## 1. Install the tools

```bash
brew install awscli eksctl kubectl helm helmfile sops age gnupg

mkdir -p ~/.config/helm
curl -sL https://github.com/jkroepke.gpg | gpg --dearmor > ~/.config/helm/jkroepke.gpg
K=~/.config/helm/jkroepke.gpg; V=4.7.9
helm plugin install --keyring $K https://github.com/jkroepke/helm-secrets/releases/download/v$V/secrets-$V.tgz
helm plugin install --keyring $K https://github.com/jkroepke/helm-secrets/releases/download/v$V/secrets-getter-$V.tgz
helm plugin install --keyring $K https://github.com/jkroepke/helm-secrets/releases/download/v$V/secrets-post-renderer-$V.tgz

# install helm-diff
helmfile init
```

## 2. Prepare the secrets

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

Put your age public key into `.sops.yaml`, then write the secrets in plain text and encrypt them:

```bash
cat > helm_chart/secrets-values.yaml <<'YAML'
secrets:
  SECRET_KEY: "<output of: openssl rand -base64 48>"
  DB_PASSWORD: "<database password>"
YAML

sops -e -i helm_chart/secrets-values.yaml
```

## 3. Set the domain and email

In `helm_chart/values.yaml`:

```yaml
config:
  SITE_ROOT: "https://hc.<your-domain>"
  ALLOWED_HOSTS: "hc.<your-domain>,localhost"
ingress:
  host: hc.<your-domain>
letsencrypt:
  email: "<your-email>"
```

## 4. Create the EKS cluster

```bash
eksctl create cluster -f infra/eks-cluster.yaml
kubectl get nodes
```

## 5. Create the RDS database

```bash
VPC=$(aws ec2 describe-vpcs --filters Name=tag:alpha.eksctl.io/cluster-name,Values=healthchecks \
  --query 'Vpcs[0].VpcId' --output text)

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=map-public-ip-on-launch,Values=false \
  --query 'Subnets[].SubnetId' --output text

aws rds create-db-subnet-group --db-subnet-group-name healthchecks-db \
  --db-subnet-group-description "healthchecks private subnets" \
  --subnet-ids <private-subnet-1> <private-subnet-2>

SG=$(aws ec2 create-security-group --group-name healthchecks-db \
  --description "Postgres from EKS VPC" --vpc-id $VPC --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 5432 --cidr 192.168.0.0/16

aws rds create-db-instance --db-instance-identifier healthchecks-db \
  --engine postgres --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 \
  --db-name hc --master-username hc \
  --master-user-password "$(sops -d --extract '["secrets"]["DB_PASSWORD"]' helm_chart/secrets-values.yaml)" \
  --db-subnet-group-name healthchecks-db --vpc-security-group-ids $SG \
  --no-publicly-accessible --no-multi-az --backup-retention-period 0 --no-deletion-protection

aws rds describe-db-instances --db-instance-identifier healthchecks-db \
  --query 'DBInstances[0].Endpoint.Address' --output text
```

Put the endpoint into `helm_chart/values.yaml`:

```yaml
config:
  DB_HOST: "<rds-endpoint>"
```

## 6. Deploy

```bash
kubectl config current-context
helmfile -f helmfile/helmfile.yaml sync
```

Later changes:

```bash
helmfile -f helmfile/helmfile.yaml diff
helmfile -f helmfile/helmfile.yaml apply
```

## 7. Point DNS at the load balancer

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

At your DNS provider, add a CNAME record:

| Type | Name | Value |
|---|---|---|
| CNAME | `hc` | `<EXTERNAL-IP value>.elb.us-east-1.amazonaws.com` |

## 8. Verify

```bash
kubectl get certificate healthchecks-tls        # READY True
curl https://hc.<your-domain>/api/v3/status/    # OK
```

## 9. Clean up

```bash
helmfile -f helmfile/helmfile.yaml destroy

aws rds delete-db-instance --db-instance-identifier healthchecks-db \
  --skip-final-snapshot --delete-automated-backups
aws rds delete-db-subnet-group --db-subnet-group-name healthchecks-db
aws ec2 delete-security-group --group-id <rds-security-group-id>

eksctl delete cluster -f infra/eks-cluster.yaml
```
