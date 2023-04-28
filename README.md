# scalably-sync

## Overview

Are you absolutely fed up with all of these different CLIs, 
syncing tools, and complex configurations? I love RSync, but I don't
want to have to manage RSync for some parts of my system and then use something like
the AWS cli for another part of my system! What if I'm multi-cloud? Do I need
to maintain separate scripts for each cloud, on prem servers, google drives,
and more?

If only there was one tool that could do it all... enter [rclone](https://rclone.org/)! [Rclone](https://rclone.org/)
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
  s3: [] # each to download FROM

uploads:
  sftp: [] # each SFTP to upload TO
  s3: [] # each S3 to uplaod TO
```

Each key in the `uploads` and `downloads` dictionaries will
be arrays of dictionaries. This will allow us to have multiple
sources or sinks of each type, and also allow us to scale the amount
of types easily.

Let's fill it out! For this blog post, we will use a vars file
that looks like the below

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
      id: "sftp1"

    - host: localhost
      port: 2222
      username: foo
      password: pass
      key: ""
      path: "/downloads"
      max_age: "168h"
      id: "sftp2"

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
      id: "sftp3"

  s3:
    - env_auth: true
      access_key: ""
      access_secret: ""
      region: us-east-1
      key_prefix: /
      bucket: scalably-sync
      id: "s31"
      max_age: "168h"
```

Note that we don't have defined schemas for each type
of source/sink. We will not implement that in this post, but
it would be a great idea! So, walking through this file, 
we can clearly see that we are going to download files from
two SFTP hosts located at `localhost:2222`. We will then sync files
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
So, in pseudo code, we will be doing something like:

```shell
for source in sources:
    set up the rclone configs for the source
    download the files on the source locally
done
```

## Bullet Three: For each type of sinks found...
This is going to be almost the same as our pseudocode above!
We will be doing something like:

```shell
for sink in sinks:
    set up the rclone configs for the sink
    upload the files from the local drive to the sink
done
```

## Writing the ansible

Now, let's get started to see how we can do that! I will be following the 
tyical ansible file layout:

```shell
- main.yml
- vars/
    - vars-file-1.yml
    - vars-file-2.yml
    .
    .
- templates/
    - template-1.j2
    - template-2.j2
    .
    .
- tasks/
    - task-set-1.yml
    - task-set-2.yml
    .
    .
```

where `main.yml` is going to be my entrypint. Our methodology is going to be
to put the sources and sinks in a uniform manner and iterate over them. We will
create task sets for each source or sink which will handle the rclone configuration
and then call rclone.

So, let's crack our main open and get started!

We will first have some pre tasks to set up our local directory as well
as load our variables from bullet 1:

```yaml
---
- name: Sync Automation
  hosts: localhost
  gather_facts: true

  pre_tasks:
    - name: Include vars file
      include_vars: "vars/{{ lookup('env', 'VARS_FILE') }}"

    - name: Create temporary sync directory
      tempfile:
        state: directory
      register: sync_dir
```

So, we will first look up the environment variable `VARS_FILE` and then load
the variables found there. By looking this up from an environment variable, 
we can have this same playbook support multiple teams with the same code.
We would just have to add more variables files. In my example, I will use one
called `compliance.yml` to simulate syncs for a fake compliance team. Next,
we use ansible to create a temporary sync directory which is where we will download
files to or from.

Next, we can get into the meat of our tasks. First, we will want to do
some ansible magic so that each source and sink have a similar structure of:

```yaml
type: type-of-source-or-sink
config: 
    config-param-1: ""
    config-param-2: ""
    .
    .
    .
```

We could have also done this in the variables files, but having some structure in here
allows us to validate the structures were we to want to do that! It also
gives us an easy to iterate format for the rest of our ansible code. So, we can use
the code below to loop through our sources and sinks and create an iteratable
array of the type above.

```yaml
  tasks:

    - name: Create iteratable sources and sinks
      set_fact:
        sources: |
          {% set sources = [] %}
          {% for type, configs in downloads.items() %}
          {% for config in configs %}
          {% set _ = sources.append({'type': type, 'config': config}) %}
          {% endfor %}
          {% endfor %}
          {{ sources }}
        sinks: |
          {% set sinks = [] %}
          {% for type, configs in uploads.items() %}
          {% for config in configs %}
          {% set _ = sinks.append({'type': type, 'config': config}) %}
          {% endfor %}
          {% endfor %}
          {{ sinks }}
```

Let's break one of these loops down, as the Jinja syntax is sometimes daunting:

```yaml
        sources: |
          # 1: Create an array called sources
          {% set sources = [] %}
          # 2: For each type (key) and config array (value)
          # in the "downloads" or "uploads" dictionary
          {% for type, configs in downloads.items() %}
          # 3: For configuration in the configs array
          {% for config in configs %}
          # 4: append a new dict object matching our above format to the sources
          # array
          {% set _ = sources.append({'type': type, 'config': config}) %}
          {% endfor %}
          {% endfor %}
          # 5: return the sources array
          {{ sources }}
```

So, up to here, we have an array called `sources` and an array called `sinks`. 
If we use the vars file posted above we would have something that looks like:

```yaml
sources: 
    - type: sftp
      config:
        host: localhost
        port: 2222
        username: foo
        password: pass
        key: ""
        path: "/downloads"
        max_age: "168h"
        id: "sftp1"
    - type: sftp
      config:
        host: localhost
        port: 2222
        username: foo
        password: pass
        key: ""
        path: "/downloads"
        max_age: "168h"
        id: "sftp2"

sinks:
    - type: sftp
      config:
        host: localhost
        port: 2222
        username: foo
        password: pass
        key: ""
        path: "/uploads"
        max_age: "168h"
        id: "sftp3"
    - type: s3
      config:
        env_auth: true
        access_key: ""
        access_secret: ""
        region: us-east-1
        key_prefix: /
        bucket: scalably-sync
        id: "s31"
        max_age: "168h"
```

In the above section, we discussed how we wanted to loop over 
the sources and sinks in a uniform manner and then each provider
or type of source/sink would have a task list associated with it:

```yaml
    - name: downloads from external sites
      include_tasks: tasks/{{ source.type }}.yml
      vars:
        local_path: "{{ sync_dir.path }}/{{ source.type }}_{{ source.config.id }}"
        config: "{{ source.config }}"
        direction: "download"
      with_items: "{{ sources }}"
      loop_control:
        loop_var: source

    - name: upload files to external sites
      include_tasks: tasks/{{ sink.type }}.yml
      vars:
        local_path: "{{ sync_dir.path }}"
        config: "{{ sink.config }}"
        direction: "upload"
      with_items: "{{ sinks }}"
      loop_control:
        loop_var: sink
```

We can see that we are including the `tasks/{{ source.type }}.yml` task set.
That would expand to something like `tasks/s3.yml` or `tasks/sftp.yml` or something
else. We would pass along with it a `local_path` which is the path on disk to
either download TO or upload FROM. We also want to pass along the configuration
to the task set with `{{ source.config }}` or `{{ sink.config }}`. We will leave
it up to our task set to pull the relevant information from the config and pass it
to rclone. Finally, we can pass a `direction` or either `upload` or `download` which tells
the task set which direction our sync is happening in.

## Provider-specific task sets
Let's crack open one of the task sets! To keep the blog post on the shorter side, I will
go over the `s3` task set located at `tasks/s3.yml`. You'll notice that it is very
simple:

```yaml
---
- name: Pull variables from config
  set_fact:
    s3_env_auth: "{{ config.env_auth }}"
    s3_access_key: "{{ config.access_key }}"
    s3_access_secret: "{{ config.access_secret }}"
    s3_region: "{{ config.region }}"
    s3_bucket: "{{ config.bucket }}"
    s3_key_prefix: "{{ config.key_prefix }}"
    max_age: "{{ config.max_age }}"

- name: Inlcude RClone Tasks
  include_tasks: rclone.yml
  vars:
    template: "rclone_s3.j2"
    raw_rclone_cmd: >-
      {% if direction == 'upload' %}
      sync "{{ local_path }}" "s3:{{ s3_bucket }}/{{ s3_bucket }}"
      {% else %}
      copy "s3:{{ s3_bucket }}/{{ s3_key_prefix }}" "{{ local_path }}"
      {% endif %}
```

All we are doing is:

1. pulling the relevant information from the `{{ source.config }}`
or `{{ sink.config }}`
2. calling another `rclone` task set with some variables

We will go over the rclone variables in more detail, but for now, it's suffice to
say that we will want to pass:

1. a template file which has the base rclone configuration file parameters
2. a command to run for the syncing or copying or other operation

## Rclone task set
The rclone task set is meant to be very generic, which means it might be a little
difficult to understand. But I will do my best to make it easy!

At this point, when we enter this task set, we have all of the required parameters
to perform an upload or a download. We also have a templatefile that we are going
to use as the rclone config, and a command we want to run.

First, we have to find where rclone expects to find the config file and then overwrite
it with the template our provider requested:

```yaml
---
- name: Find Rclone config file location
  shell: rclone config file
  register: _rclone_config

- name: pull rclone configuration
  set_fact:
    rclone_config: "{{ _rclone_config.stdout_lines[1] }}"

- name: template rclone config
  template:
    src: "templates/{{ template }}"
    dest: "{{ rclone_config }}"
    mode: 0600
  no_log: true
```

This will use the `rclone config file` cli command to find where rclone expects to find the
file. It write this info to stdout, so we will capture that and save it in the 
`rclone_config` ansible fact. Then we use the `template` ansible module to write our
template that to `rclone_config` location. The S3 template looks like:

```shell
[s3]
type = s3
provider = AWS
env_auth = {{ s3_env_auth }}
{% if not s3_env_auth %}
access_key = {{ s3_access_key }}
access_secret = {{ s3_access_secret }}
{% endif %}
region = {{ s3_region }}
{% if s3_endpoint is defined and s3_endpoint != "" %}
endpoint = {{ s3_endpoint }}
{% endif %}
```

Next, we just have to run the command and then clean up our config file:

```yaml
- name: Set RClone Flags
  set_fact:
    rclone_flags: "--config {{ rclone_config }} --contimeout=2m0s --max-age {{ max_age }}"

- name: Set RClone Command
  set_fact:
    rclone_cmd: >-
      rclone {{ raw_rclone_cmd }} {{ rclone_flags }}

- name: Run the sync
  shell: |
    {{ rclone_cmd }}
  register: rclone_results

- name: Show run results
  debug:
    msg:
      - "stdout"
      - "{{ rclone_results.stdout_lines }}"
      - "stderr"
      - "{{ rclone_results.stderr_lines }}"

- name: Remove rclone_config
  file:
    path: "{{ rclone_config }}"
    state: absent
```

We use the rclone cli, with the commands we built previously, to perform the sync. It
will use the configuration parameters we templated into our rclone config file, and
then it will remove the config (in case there is any sensitive info in there). And
that's it!

The process is exactly the same for both sources and sinks, making it flexible and
easy to add more or less!

## Running

I am using an SFTP site in a docker container, so if you'd like
to follow along, there's a `docker/` directory with a `docker-compose` file.

You can simply run `dokcer-compose up -d` in one terminal.

I am also using an S3 hosted bucket. If you want to sync to or from S3, 
please change it from the default (becasue it won't work!).

You can run this like below:

```shell
#!/bin/bash

export VARS_FILE="compliance.yml"

ansible-playbook main.yml
```

You might get a lot of output, but you'll see that your files get copied and 
synced from your `sources` to your `sinks`. Thanks for following along!