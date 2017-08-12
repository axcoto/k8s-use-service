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

Awesone, it switchs to **BLUE**. Now it has error, we can immediately rollback:

```
$ make switch
$ kubectl run -it --rm cli --image byrnedo/alpine-curl  --restart=Never -- 100.66.101.132
BLUE
```

We can repeast this process for next deployment:

```
make deploy # default color=blue without specifiyicng
make switch
```

# Stateful database

The basic idea is that we will use *Service* with a specific selector.
Then we run a MySQL pod with that selector as its label, we enable binlog
on this MySQL container. We consider this the primary server.

When we need to upgrade the database, we simply create another container,
configure it to be replicated from above master, make it effectively become
secondary. Until the data is up to day, and secondary keeps up with the primary.
We can temporarily take the app down or set the app in read-only mode to prevent
write.

Then we do 3 things:

- Change the label of primary pod to something else.
- Promote slave to primary
- Change the label of the slave(which is a standalone primary now) to the selector
that we config on service

This way the downtime is minimal and if anything occurs, we can still rollback to old
primary database.

## Try out
