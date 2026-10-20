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

All resources live in `us-east-1`. Note that `AWS_DEFAULT_REGION` and `AWS_REGION` override the region in `~/.aws/config`, and `aws configure get region` does not show them. If either variable is set to another region, the commands below find nothing (e.g. `VPC` becomes `None`):

```bash
export AWS_DEFAULT_REGION=us-east-1
```

`infra/eks-cluster.yaml` also enables OIDC and installs the `aws-efs-csi-driver` addon, which is needed for the static files volume.

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

## 6. Create the EFS filesystem for static files

Static files are stored on Amazon EFS (`ReadWriteMany`), so pods on every node share one volume. Run this in the same shell as step 5 (it uses `$VPC`).

Check that the EFS CSI driver is running (one controller, and one `efs-csi-node` pod per node):

```bash
kubectl get pods -n kube-system | grep efs
```

Security group for NFS, the filesystem, and one mount target per subnet the nodes run in (the nodes are in the public subnets):

```bash
EFS_SG=$(aws ec2 create-security-group --group-name healthchecks-efs \
  --description "NFS from EKS nodes" --vpc-id $VPC --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $EFS_SG --protocol tcp --port 2049 --cidr 192.168.0.0/16

FS_ID=$(aws efs create-file-system --encrypted --performance-mode generalPurpose \
  --tags Key=Name,Value=healthchecks-static --query FileSystemId --output text)
aws efs describe-file-systems --file-system-id $FS_ID --query 'FileSystems[0].LifeCycleState'   # "available"

SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[].SubnetId' --output text)
for s in $(echo $SUBNETS); do
  aws efs create-mount-target --file-system-id $FS_ID --subnet-id $s --security-groups $EFS_SG
done
aws efs describe-mount-targets --file-system-id $FS_ID --query 'MountTargets[].LifeCycleState'  # all "available"
```

Access point. The container runs as uid 1000, and the EFS root directory is owned by root. The access point exposes a directory owned by uid 1000:

```bash
AP_ID=$(aws efs create-access-point --file-system-id $FS_ID \
  --posix-user Uid=1000,Gid=1000 \
  --root-directory 'Path=/healthchecks-static,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}' \
  --tags Key=Name,Value=healthchecks-static --query AccessPointId --output text)
echo $FS_ID $AP_ID
```

Put both IDs into `helm_chart/values.yaml`:

```yaml
storage:
  efsFileSystemId: "<fs-id>"
  efsAccessPointId: "<fsap-id>"
```

## 7. Deploy

```bash
kubectl config current-context
helmfile -f helmfile/helmfile.yaml sync
```

Later changes:

```bash
helmfile -f helmfile/helmfile.yaml diff
helmfile -f helmfile/helmfile.yaml apply
```

## 8. Point DNS at the load balancer

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

At your DNS provider, add a CNAME record:

| Type | Name | Value |
|---|---|---|
| CNAME | `hc` | `<EXTERNAL-IP value>.elb.us-east-1.amazonaws.com` |

## 9. Verify

```bash
kubectl get certificate healthchecks-tls        # READY True
curl https://hc.<your-domain>/api/v3/status/    # OK
```

Static files volume:

```bash
kubectl get pv,pvc                                         # both Bound, RWX, efs-sc
kubectl get pods -o wide                                   # pods Running on both nodes
kubectl exec deploy/healthchecks -- ls /app/static-collected
kubectl exec deploy/healthchecks -- sh -c "mount | grep static-collected"   # type nfs4
curl -I https://hc.<your-domain>/static/img/favicon.svg    # HTTP 200
```

## 10. Clean up

```bash
helmfile -f helmfile/helmfile.yaml destroy

aws rds delete-db-instance --db-instance-identifier healthchecks-db \
  --skip-final-snapshot --delete-automated-backups
aws rds delete-db-subnet-group --db-subnet-group-name healthchecks-db
aws ec2 delete-security-group --group-id <rds-security-group-id>
```

The PV uses `reclaimPolicy: Retain`, so `helmfile destroy` removes the Kubernetes objects but the files stay on EFS. Delete EFS **before** the cluster. Its mount targets keep the VPC in use, and `eksctl delete cluster` fails otherwise:

```bash
aws efs delete-access-point --access-point-id <fsap-id>
for mt in $(aws efs describe-mount-targets --file-system-id <fs-id> --query 'MountTargets[].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $mt
done
aws efs describe-mount-targets --file-system-id <fs-id> --query 'MountTargets'   # wait until []
aws efs delete-file-system --file-system-id <fs-id>
aws ec2 delete-security-group --group-id <efs-security-group-id>
```

```bash
eksctl delete cluster -f infra/eks-cluster.yaml
```
