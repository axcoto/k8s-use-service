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

You should alwyays source `env.sh` before running any `make` command of this repository.

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
primary database. The IP address also remains same.

## Bring up db

This bring up master, and automatically create EBS volume to store data. When the pod is destroy, the data on EBS volume
remains.

```
$ make db
$ kubectl get pv # check ebs volume status
pvc-8d3ea83b-7f9a-11e7-ba1e-028c050a0436   1Gi        RWO           Delete          Bound     default/data-mysql-0             gp2                      4h
```

Once the pod are ready, we can connect to its MySQL shell:

```
$ make mysql_shell
kubectl run --image=mysql:5.7 -i -t --rm --restart=Never cli -- mysql -h 100.71.164.136
If you don't see a command prompt, try pressing enter.

mysql> select @@hostname;
+-------------------+
| @@hostname        |
+-------------------+
| mysql-0 |
+-------------------+
1 row in set (0.00 sec)
```

## Upgrade process

1. Bring up slave

   ```
   $ make secondary_db
   # We can watch it status
	 $ kubectl get pods mysql-secondary-0
		 NAME                READY     STATUS     RESTARTS   AGE
		 mysql-secondary-0   0/1       Init:0/1   0          13s
	 $ kubectl get pods mysql-secondary-0
		 NAME                READY     STATUS    RESTARTS   AGE
		 mysql-secondary-0   1/1       Running   0          58s
  	```

2. Setup replication on secondary db

		It's possible to automate this process but for now, we do it manually. We also
		skip initialize steps to dumb data and sync to master.

		 ```
		 # Ensure both are in running state
		 $ kubectl get pods | grep mysql
			 mysql-0                                   1/1       Running   0          48m
			 mysql-secondary-0                         1/1       Running   0          8m
		 $ make config_slave # this will setup replication for secondary StatefulSet
		 ```

		Wait until slave keep up with master (second_behind_master=0) and has no replication error.

3. Switch Over

		This is when downtime happen. We need to stop the app or put it into READ-ONLY mode
		Then promote slave to master and switch mysql service selector to the label of 
		secondary StatefulSet

		```
    $ make promote_db
		```

		The migration process is finished. Downtime is the amount of time to promoting and change selector. Which is usually
		a few seconds.

		We can check the selector of mysql service now

		```
	  $ kubectl describe services mysql
    ```

		We can verify if new node as well:

		```
		make mysql_shell
		kubectl run --image=mysql:5.7 -i -t --rm --restart=Never cli -- mysql -h 100.71.164.136
		If you don't see a command prompt, try pressing enter.

		mysql> select @@hostname;
		+-------------------+
		| @@hostname        |
		+-------------------+
		| mysql-secondary-0 |
		+-------------------+
		1 row in set (0.00 sec)
		```

# Teardown

```
make destroy
```
