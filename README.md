K8S cluster provision with kops, demo blue-green deployment and stateful database

# Pre-Requirement

## IAM
You have to create an IAM role on AWS to use as IAM instance role for the server.
This IAM role need these IAM permissions:

```
AmazonEC2FullAccess
AmazonRoute53FullAccess
AmazonS3FullAccess
IAMFullAccess
AmazonVPCFullAccess
```

You can either create them from AWS console or run this script if you have AWS CLI
access

```
make iam
# Note, if you have multiple aws profile config you can run
# make iam profile=your-profile-name to create profile under this
```

This will create an `kops` iam user and return the credential. Note those credential, you need
them in next step

# Setup

## Step 1: Define environment vars

Creata a file call `env.sh` to your preference from the template `env.sh.template`, especially the AWS keys

# Step 2: Bring up cluster

```
source env.sh
make deps # install dependencies include: kubectl and kops
make up # bring up cluster on AWS
```

This will run for awhile and take couple of minute for clustet to come up

# Blue-green deployment

To achieve blue-green deployment. We create a service with a selector to
specific color. We run `nginx` as a deployment with a label for that color.

We later on create other deployment, but with other label color, we run
smoke test on new pods, then change the selector of service to those new
pods.


## Try out

Let's deploy nginx, in practice, it will be a reverse proxy, but for this,
we simply serve a blue-green page.

```
make deploy
```

We can check and see that pod/serice are deloy:

```
$ kubectl get services
NAME               CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
kubernetes         100.64.0.1       <none>        443/TCP   31m
nginx-lb-service   100.66.101.132   <none>        80/TCP    42s

$ kubectl get pods
NAME                                     READY     STATUS    RESTARTS   AGE
nginx-deployment-blue-1403469014-bsczp   1/1       Running   0          1m
```

Let's see if we can access above nginx pod by hitting IP address of service

```
kubectl run -it --rm cli --image byrnedo/alpine-curl  --restart=Never -- 100.66.101.132
BLUE
```

Awesone, it returns **BLUE**

Now, let's deoloy other nginx:

```
make deploy color=green
```

Do some quick test/healthcheck, up to us. Then switch over

```
$ make switch
Switch from green to blue
service "nginx-lb-service" configured
```

`switch` toggle between two deployment allow us to quickly rollback too.

Now, let's see what we get, with the same IP:

```
$ kubectl run -it --rm cli --image byrnedo/alpine-curl  --restart=Never -- 100.66.101.132
GREEN
```

Awesone, it switchs to **GREEN**. If it has error, we can immediately rollback:

```
$ make switch
$ kubectl run -it --rm cli --image byrnedo/alpine-curl  --restart=Never -- 100.66.101.132
BLUE
```

We can repeast this process for next deployment as much as we want

```
make deploy # default color=blue without specifiyicng
make switch
```

# Stateful database

The basic idea is that we will use *Service* with a specific selector 
to select pods.

Then we run a MySQL pod with that selector as its label, we enable binlog
on this MySQL container. We consider this the primary server.

When we need to upgrade the database, we follow this process:

- Create another MySQL pod, configure it to be replicated from above master,
  make it effectively become secondary.
- Wait till this secondary as up-to-date data with master
- Then start downtime:

  - Temporarily take the app down or set the app in read-only mode to prevent write.
  - Change selector of MySQL service to match the label of this new pod
- Finish downtime, switching to new db server is done

This way the downtime is minimal and if anything occurs, we can still rollback to old
primary database. The IP address is also remain same.

## Bring up db

We will create ebs volume first, and use it as param for next command

```
make ebs # note volume id
make db EBS_VOLUME=[volume-id-from-above]
```

Once the pod are ready, we can connect to its MySQL shell:

```
make mysql_shell
```

## Upgrade process

1. Bring up slave

   ```
   mak ebs # note volume id or we can re-use any existing volume id
   make secondary_db EBS_VOLUME=[ebs-volume-id]
   # Manually connect to this pod and setup replication.
   # We can do some more work do automate this further without human intervention
   # Ideally, we can use mysqldump to backup data, find the MASTER_LOG_POS from dump file
   # then import data into this new slave pod, and issue change master command from above MASTER_LOG_POS
   # CHANGE MASTER TO MASTER_HOST='USING_SERVICE_IP_ADDRESS',MASTER_USER='replicant',MASTER_PASSWORD='<<slave-server-password>>', MASTER_LOG_FILE='<<value from dump file>>', MASTER_LOG_POS=<<value from dump file>>;
   # START_SLAVE'
   ```

2. Switch Over

This is the amount of time we are down

		```
		# 1. Stop the app or put it into READ-ONLY mode
    # Promote slave to master and switch mysql selector to the slave(new master) StatefulSet
    make promote_db
		```

The migration process is finished. Downtime is the amount of time to promoting and change selector. Which is usually
a few seconds.
