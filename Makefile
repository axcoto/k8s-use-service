#!/usr/bin/make -f

profile ?= default

# Detect OS for OS agnostic
UNAME_S := $(shell uname -s)

# Pre-define resource URl based on OS
ifeq ($(UNAME_S),Linux)
	KUBECTL_URL := "https://storage.googleapis.com/kubernetes-release/release/v1.7.0/bin/linux/amd64/kubectl"
	KOPS_URL := "https://github.com/kubernetes/kops/releases/download/1.7.0/kops-linux-amd64"
	KOPS := "./bin/linux/kops"
endif
ifeq ($(UNAME_S),Darwin)
	KUBECTL_URL := "https://storage.googleapis.com/kubernetes-release/release/v1.7.0/bin/darwin/amd64/kubectl"
	KOPS_URL := "https://github.com/kubernetes/kops/releases/download/1.7.0/kops-darwin-amd64"
	KOPS := "./bin/mac/kops"
endif

# Install deps
# kops will be installed locally but we install kubectl globally
deps:
	@test -e $(KOPS) || curl -sL $(KOPS_URL) -o $(KOPS)
	@chmod +x $(KOPS)
	@if ! which kubectl; then \
		curl -sLO $(KUBECTL_URL) -o kubectl; \
		sudo mv kubectl /usr/local/bin/kubectl; \
		sudo chmod +x kubectl; \
	fi

# Shortcut to create IAM using aws cli
iam:
	aws iam create-group --group-name kops --profile $(profile)
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess --group-name kops --profile $(profile)
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess --group-name kops --profile $(profile)
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --group-name kops --profile $(profile)
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/IAMFullAccess --group-name kops --profile $(profile)
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess --group-name kops --profile $(profile)
	aws iam create-user --user-name kops --profile $(profile)
	aws iam add-user-to-group --user-name kops --group-name kops --profile $(profile)
	aws iam create-access-key --user-name kops --profile $(profile)

# Check requirement
check_requirement:
	@echo "Check requirement"
	@which aws > /dev/null || (echo "Please install awscli"; exit 1;)
	@if  [ ! -e "${HOME}/.ssh/id_rsa.pub" ]; then echo "Please create ssh keypair first"; exit 1; fi
	@if  [ ! -e "./env.sh" ]; then echo "Please create env.sh file"; exit 1; fi
	@echo "Requirement OK!"

create_bucket:
	@echo "Create S3 Bucket for Kops"
	@aws s3 mb s3://"${S3_BUCKET}" --region "${AWS_REGION}"

info:
	bin/mac/kops validate cluster

up: check_requirement create_bucket
	@echo "Start Deploy cluster"
	#($(KOPS) get clusters --state s3://"${S3_BUCKET}" | grep -q "${CLUSTER_NAME}") || (echo "Cluster is already exist. Please destroy them first with `make destroy`"; exit 1)
	kops create cluster --zones ${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c --master-zones ${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c ${CLUSTER_NAME} --node-size=${NODE_SIZE} --master-size=${MASTER_SIZE} --node-count=${NODE_COUNT} --yes;


destroy:
	bash -c 'source env.run; ./bin/mac/kops delete cluster "$$CLUSTER_NAME" --yes'

# Create configmape for nginx
config_map:
	@kubectl create configmap data-blue  --from-file=specs/lb/blue > /dev/null 2>&1 || true
	@kubectl create configmap data-green --from-file=specs/lb/green > /dev/null 2>&1 || true

# Dep
deploy: config_map
	@mkdir .deploy > /dev/null 2>&1 || true
	$(eval color ?= blue)
	@sed -e "s/\@COLOR@/$(color)/" specs/lb/nginx-service.yml > .deploy/nginx-service.yaml
	@sed -e "s/\@COLOR@/$(color)/" specs/lb/nginx-deployment.yml > .deploy/nginx-deployment.yaml
	@echo "Create deploy: $(color)"
	@(kubectl get service nginx-lb-service >/dev/null 2>&1) || (kubectl create -f .deploy/nginx-service.yaml)
	@(kubectl create -f .deploy/nginx-deployment.yaml) || (kubectl apply -f .deploy/nginx-deployment.yaml)

switch:
	$(eval current_color := $(shell kubectl describe service nginx-lb-service | grep Selector | awk -F 'color=' '{print $$NF}'))
  ifeq ($(current_color), blue)
		@echo "Switch from blue to green"
		@sed -e "s/\@COLOR@/green/" specs/lb/nginx-service.yml > .deploy/nginx-service.yaml
  else
		@echo "Switch from green to blue"
		@sed -e "s/\@COLOR@/blue/" specs/lb/nginx-service.yml > .deploy/nginx-service.yaml
  endif
	@kubectl apply -f .deploy/nginx-service.yaml 2>/dev/null

# bring up master
db:
	kubectl create -f specs/database/mysql.yml 2>/dev/null || true
	@sleep 3
	kubectl get services | grep -q mysql
	kubectl create -f specs/database/mysql-master.yml

# bring up slave
secondary_db:
	kubectl create -f specs/database/mysql-secondary.yml
config_secondary:
	$(eval MASTER := $(shell kubectl get services mysql-secondary | tail -n1 | awk '{print $$2}'))
	$(eval FILE :=   $(shell kubectl exec -it mysql-0 -- mysql -e 'show master status\G;' | head -n2 | tail -n1 | awk '{print $$2}'))
	$(eval POS :=    $(shell kubectl exec -it mysql-0 -- mysql -e 'show master status\G;' | head -n3 | tail -n1 | awk '{print $$2}'))
	kubectl exec -it mysql-secondary-0 -- mysql -h 127.0.0.1 -e "STOP SLAVE; CHANGE MASTER TO MASTER_HOST='$(MASTER)', MASTER_LOG_FILE='$(FILE)', MASTER_LOG_POS=$(POS), MASTER_USER='root', MASTER_PASSWORD=''; START SLAVE; SHOW SLAVE STATUS \G;"

# Promote pod into master
# Change labl
promote_db:
	$(eval MYSQL_HOST := $(shell kubectl get services mysql-secondary | tail -n1 | awk '{print $$2}'))
	kubectl run -it --rm --image=mysql:5.7 --restart=Never mysql-cli -- mysql -h $(MYSQL_HOST) -e "STOP SLAVE; RESET MASTER;"
	kubectl patch services mysql -p '{"spec":{"selector":{"app":"mysql-secondary"}}}'

# Create an interaction shell with node in cluster
shell:
	kubectl run -it --rm shell --image busybox  --restart=Never -- sh
mysql_shell:
	$(eval MYSQL_HOST := $(shell kubectl get services mysql | tail -n1 | awk '{print $$2}'))
	kubectl run --image=mysql:5.7 -i -t --rm --restart=Never cli -- mysql -h $(MYSQL_HOST)
secondary_shell:
	$(eval MYSQL_HOST := $(shell kubectl get services mysql-secondary | tail -n1 | awk '{print $$2}'))
	kubectl run --image=mysql:5.7 -i -t --rm --restart=Never cli -- mysql -h $(MYSQL_HOST)

