# scalably-sync

## Overview

Are you absolutely fed up with all of these different CLIs, 
syncing tools, and complex configurations? I love RSync, but I don't
to have to manage RSync for some parts of my system and then use something like
the AWS cli for another part of my system! What if I'm multi-cloud? Do I need
to maintain separate scripts for each cloud, on prem servers, google drives,
and more?

If only there was one tool that could do it all... enter [rclone]()! [Rclone]()
is one of my favorite syncing utilities because it's:

* fast
* configurable
* easy to use
* has plugins for SO MANY storage types

In this article, we will use rclone to sync things to SFTP, on-disk, and S3.
However, this could be applied to hundreds more storage providers including:

* Google Drive
* Google Storage Buckets
* Azure Storage Buckets
* Arbitrary HTTP Endpoints (Think something like Nexus / Artifactory)
* Much, Much, More

Now, we will also want to wrap Rclone with a pretty interface that is also
configurable and allows us to reuse our code, create templates, and perform
things like error checking. For that, we will use ansible. So, TLDR; is that
we're going to create a robust syncing system with rclone and then wrap it 
with ansible.

## RClone

Before continuing, I would recomment installing Rclone with the
[steps outlined here](https://rclone.org/install/) (also shown below):

```shell
sudo -v ; curl https://rclone.org/install.sh | sudo bash
```

You can then verify the installation with 

```shell
prompt> rclone version
rclone v1.61.1
- os/version: darwin 13.3.1 (64 bit)
- os/kernel: 22.4.0 (arm64)
- os/type: darwin
- os/arch: arm64
- go/version: go1.19.4
- go/linking: dynamic
- go/tags: none
```

Rclone works by loading plugins and configuring them based on a configuration file.
It then interacts with the relevant API's using the provided configuration to
sync/copy/stat files on either local or remote locations.

An example rclone configuration file might be located at `$HOME/.config/rclone/rclone.conf`
and might look similar to the below:

```
[sftp]
type = sftp
host = localhost
user = foo
port = 2222
pass = bar
set_modtime = false
```

This says "Hey Rclone, log in to an SFTP server at localhost:2222 with foo:bar as 
your credentials". There are tons of [supported storage mediums] 
(https://rclone.org/overview/) each with their own configurations.

## The code

I will assume that, at this point, you have both Rclone and Ansible installed!

Let's get started. From a high level, we are going to:

* Have ansible read a set of sources and sinks from a vars file

* For each type of source found:
    * For each source in the source types:
        * Use RClone to download the files to some place on disk locally

* For each type of sinks found:
    * For each sink in the sink types:
        * Use RClone to upload the files from some place on disk

## Bullet 1:  Have ansible read a set of sources and sinks from a vars file

Let's start with the first bullet. Ansible can load variable files
from a local file path and create ansible facts/vars from that file. This
seems like a great tool for us to use for our configurations! A skeleton might
look like:

```yaml
downloads:
  sftp: [] # each SFTP to download FROM
  s3: [] # each S# to download FROM

uploads:
  sftp: [] # each SFTP to upload TO
  s3: [] # each S3 to uplaod TO
```

Each key in the `uploads` and `downloads` dictionaries will
be arrays of dictionaries. This will allow us to have multiple
sources or sinks of each type, and also allow us to scale the amount
of types easily.

Let's fill it out! It might look something like:

```yaml
downloads:

  sftp: 
    - host: localhost
      port: 2222
      username: foo
      password: pass
      key: ""
      path: "/downloads"
      max_age: "168h"

  s3: []

uploads:

  sftp:
    - host: localhost
      port: 2222
      username: foo
      password: pass
      key: ""
      path: "/uploads"
      max_age: "168h"

  s3:
    - env_auth: true
      access_key: ""
      access_secret: ""
      region: us-east-1
      key_prefix: /
      bucket: scalably-sync
```

Note that we don't have defined schemas for each type
of source/sink. We will not implement that in this post, but
it would be a great idea! So, walking through this file, 
we can clearly see that we are going to download files from
an SFTP host located at `localhost:2222`. We will then sync files
to an SFTP host also located at `localhost:2222` and then an S3 bucket
called `scalably-sync`.

Now, looking this up is very easy in ansible. We can use the `include_vars` 
directive which looks up a vars file and then saves the variables in memory.

It might look something like 

```yaml
    - name: Include vars file
      include_vars: "vars/{{ lookup('env', 'VARS_FILE') }}"
```

But don't worry too much about this just yet. We will come back to it when we
put everything together.

## Bullet Two: For each type of source found...
