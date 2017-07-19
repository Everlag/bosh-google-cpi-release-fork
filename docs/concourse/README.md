# Deploying Concourse on Google Compute Engine

This guide describes how to deploy [Concourse](http://concourse.ci/) on [Google Compute Engine](https://cloud.google.com/) using BOSH. You will deploy a BOSH director as part of these instructions.

## Prerequisites
* You must have the `terraform` CLI installed on your workstation. See [Download Terraform](https://www.terraform.io/downloads.html) for more details.
* You must have the `gcloud` CLI installed on your workstation. See [cloud.google.com/sdk](https://cloud.google.com/sdk/).

### Setup your workstation

1. Set your project ID:

  ```
  export projectid=REPLACE_WITH_YOUR_PROJECT_ID
  ```

1. Export your preferred compute region and zone:

  ```
  export region=us-east1
  export zone=us-east1-c
  export zone2=us-east1-d
  ```

1. Configure `gcloud` with a user who is an owner of the project:

  ```
  gcloud auth login
  gcloud config set project ${projectid}
  gcloud config set compute/zone ${zone}
  gcloud config set compute/region ${region}
  ```
  
1. Create a service account and key:

  ```
  gcloud iam service-accounts create terraform-bosh
  gcloud iam service-accounts keys create /tmp/terraform-bosh.key.json \
      --iam-account terraform-bosh@${projectid}.iam.gserviceaccount.com
  ```

1. Grant the new service account editor access to your project:

  ```
  gcloud projects add-iam-policy-binding ${projectid} \
      --member serviceAccount:terraform-bosh@${projectid}.iam.gserviceaccount.com \
      --role roles/editor
  ```

1. Make your service account's key available in an environment variable to be used by `terraform`:

  ```
  export GOOGLE_CREDENTIALS=$(cat /tmp/terraform-bosh.key.json)
  ```

### Create required infrastructure with Terraform

1. Download [main.tf](main.tf) and [concourse.tf](concourse.tf) from this repository.

1. In a terminal from the same directory where the 2 `.tf` files are located, view the Terraform execution plan to see the resources that will be created:

  ```
  terraform plan -var projectid=${projectid} -var region=${region} -var zone-1=${zone} -var zone-2=${zone2}
  ```

1. Create the resources:

  ```
  terraform apply -var projectid=${projectid} -var region=${region} -var zone-1=${zone} -var zone-2=${zone2}
  ```

### Deploy a BOSH Director

1. SSH to the bastion VM you created in the previous step. All SSH commands after this should be run from the VM:

  ```
  gcloud compute ssh bosh-bastion-concourse
  ```

1. Install [bosh-cli V2](https://bosh.io/docs/cli-v2.html#install)

1. Configure `gcloud` to use the correct zone, region, and project:

  ```
  zone=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone)
  export zone=${zone##*/}
  export region=${zone%-*}
  gcloud config set compute/zone ${zone}
  gcloud config set compute/region ${region}
  export project_id=`curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id`
  ```

1. Explicitly set your secondary zone:

  ```
  export zone2=us-east1-d
  ```

1. Create a **password-less** SSH key:

  ```
  ssh-keygen -t rsa -f ~/.ssh/bosh -C bosh
  ```

1. Run this `export` command to set the full path of the SSH private key you created earlier:

  ```
  export ssh_key_path=$HOME/.ssh/bosh
  ```

1. Navigate to your [project's web console](https://console.cloud.google.com/compute/metadata/sshKeys) and add the new SSH public key by pasting the contents of ~/.ssh/bosh.pub:

  ![](../img/add-ssh.png)

  > **Important:** The username field should auto-populate the value `bosh` after you paste the public key. If it does not, be sure there are no newlines or carriage returns being pasted; the value you paste should be a single line.

1. Create and `cd` to a directory:

  ```
  mkdir google-bosh-director
  cd google-bosh-director
  ```

1. Use `vim` or `nano` to create a BOSH Director deployment manifest named `manifest.yml.erb`:

  ```
  ---
  <%
  ['region', 'project_id', 'zone', 'ssh_key_path'].each do |val|
    if ENV[val].nil? || ENV[val].empty?
      raise "Missing environment variable: #{val}"
    end
  end

  region = ENV['region']
  project_id = ENV['project_id']
  zone = ENV['zone']
  ssh_key_path = ENV['ssh_key_path']
  %>
  name: bosh

  releases:
    - name: bosh
      url: https://bosh.io/d/github.com/cloudfoundry/bosh?v=262.3
      sha1: 31d2912d4320ce6079c190f2218c6053fd1e920f
    - name: bosh-google-cpi
      url: https://bosh.io/d/github.com/cloudfoundry-incubator/bosh-google-cpi-release?v=25.8.0
      sha1: bb943b492c025903b6c4a833e2f836e5c1479bbc

  resource_pools:
    - name: vms
      network: private
      stemcell:
        url: https://bosh.io/d/stemcells/bosh-google-kvm-ubuntu-trusty-go_agent?v=3421.11
        sha1: e055682ebd86a2f48dc82bbc114c7de20b5a5393
      cloud_properties:
        zone: <%=zone %>
        machine_type: n1-standard-4
        root_disk_size_gb: 40
        root_disk_type: pd-standard
        service_scopes:
          - compute
          - devstorage.full_control

  disk_pools:
    - name: disks
      disk_size: 32_768
      cloud_properties:
        type: pd-standard

  networks:
    - name: vip
      type: vip
    - name: private
      type: manual
      subnets:
      - range: 10.0.0.0/29
        gateway: 10.0.0.1
        static: [10.0.0.3-10.0.0.7]
        cloud_properties:
          network_name: concourse
          subnetwork_name: bosh-concourse-<%=region %>
          ephemeral_external_ip: true
          tags:
            - bosh-internal

  jobs:
    - name: bosh
      instances: 1

      templates:
        - name: nats
          release: bosh
        - name: postgres-9.4
          release: bosh
        - name: powerdns
          release: bosh
        - name: blobstore
          release: bosh
        - name: director
          release: bosh
        - name: health_monitor
          release: bosh
        - name: google_cpi
          release: bosh-google-cpi

      resource_pool: vms
      persistent_disk_pool: disks

      networks:
        - name: private
          static_ips: [10.0.0.6]
          default:
            - dns
            - gateway

      properties:
        nats:
          address: 127.0.0.1
          user: nats
          password: nats-password

        postgres: &db
          listen_address: 127.0.0.1
          host: 127.0.0.1
          user: postgres
          password: postgres-password
          database: bosh
          adapter: postgres

        dns:
          address: 10.0.0.6
          domain_name: microbosh
          db: *db
          recursor: 169.254.169.254

        blobstore:
          address: 10.0.0.6
          port: 25250
          provider: dav
          director:
            user: director
            password: director-password
          agent:
            user: agent
            password: agent-password

        director:
          address: 127.0.0.1
          name: micro-google
          db: *db
          cpi_job: google_cpi
          ssl:
            key: |
              -----BEGIN PRIVATE KEY-----
              MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDQeFoYJhAGBtwg
              MNU5TwrRsyTfDM8UEJbYRHqMc+cPWMRUqmhz6Nliv/nPrb77/KNcViBtrRRD91zQ
              L+dL3wNWR/FMzuXzB1MDy4UTHb09EjSDRT+W/bMlUheYF7lM12zVwYAUzv7NQZVd
              Tm7aecWHNsA4mTCddMwAp7T5XcGd7nFIFUxcKpiwzGQvfp8I/dQ5H1IqUHnm7ON4
              E9POwRw0pUeRBaK9Qr25SLv4h8SHE0cGcoeEw73vNQMmDB0hD3wUFbtquWXi5A7F
              Dx9zRO8fr9d4QI7Zlh3qNG9cp3hrxtG9W8ot2qpDR2E9BUk/knm5gyc4m74FBPlX
              9ZdMij2hAgMBAAECggEAK0YQTZr5EIc0AmqgmDjUIhtxt+tMwPmAlnwAhE8603C1
              sG1/KTBYj6sSDA4g6uXSc0RdjuayojkixwRqmtE8PBjK+gqoqP4IOW1xvjoaIic5
              R1aEkK8xFLops6SZDl5ZdTWphKhDNBA9FRVG5YsJebvfwt/pu4WXIzus0Wao3kNU
              ivNkPdGUZidE4LCRFRt/HGnzCNazSZ/W72Db/pQtGXqWsqofSvhKHQjI8wCl3A8y
              Gs7FWU+Trl6fQFGjLs+bPWxrx5/+Y5LfkT6qgi7RbqEhDn3YJkYXXGUfmjg8+E/Z
              ttJALDo/ZPXjsKKKN3s02A5ux6ENk4NyEsxrVK+7AQKBgQD4/CBtTgF4KEftalaG
              4ps5YtD4834Yfbl+KkwSs1ImaPdZgET/prNGrR6MGFeA0oNsx/h/AJW+NqDJtBIM
              oTm112vvFw3RFVhEfkxOmndL555DkI9CvY5SPFEbk4qTk6UooeHwp5r78Hx/hkjo
              yPfQF8C5kewYK6bdTehR/9s1+QKBgQDWWABT7g9+LTgBf0bsKNu2nTrdCcbJR7id
              2QmNyEEzaYfWyGaTL2h0KYql+0Gi1fZ7luegVp9qRP5Aimxpdl+iUBb+whk28mfT
              iFsrwmwq6DtvVHszy187HDpEN3bvOLCjozEn6ULZeBpuk1Do9/hLewIOF5jknYHV
              d5nWtEaO6QKBgBrNkXQS1KeptmyBaQUmOc2IrLRQCf/68M/7H6tXsH1ACXiSDVt0
              B5KRKlusdycAAnPgZwjM+FG8sbxk7Rh89qhzo0PeuHcMlC7zZaWEjVkXevsNAc8O
              dta1dYnBbUaLu1jPbHIqqM18Svqzav/cOoklNXMEmWTUtibWry68m02JAoGBAKAq
              qjQNVC5pA8y6mviln2jaHL5HK/AEVAQ/xk/YMECGvybUITIi3t7Om/hjxCw1zjWU
              EglSMVVrsMHxrgkwl03mowhDaiwQ/1ymK9qLMeDuIFuUuWt+sO6urSuEdq9ToUrm
              CzlTqMxwXu/5zSAJC9T7WhHFuE49FGO7N42ksIThAoGBALCg3FBLj+8m7FahO7T2
              O7GUhUdtavRoMZNrJJpEqES9Z57BN4ToBBE9B+d/ZO2ry3DBek1DsvZ1zMTj/kHU
              t6UNDfaqgi6hWQvJ6lA7sPfLUwBAZ9k4U4hv6Gp1kVE+jNKmb9QiRY5pxbjQ7lZq
              PgKm6ag/pe+0FYobED0hR1ve
              -----END PRIVATE KEY-----
            cert: |
              -----BEGIN CERTIFICATE-----
              MIICsjCCAZoCCQDYQJGuufwE6jANBgkqhkiG9w0BAQsFADAbMQ0wCwYDVQQKDARC
              b3NoMQowCAYDVQQDDAEqMB4XDTE3MDcwNjE3MDQ0NloXDTI3MDcwNDE3MDQ0Nlow
              GzENMAsGA1UECgwEQm9zaDEKMAgGA1UEAwwBKjCCASIwDQYJKoZIhvcNAQEBBQAD
              ggEPADCCAQoCggEBANB4WhgmEAYG3CAw1TlPCtGzJN8MzxQQlthEeoxz5w9YxFSq
              aHPo2WK/+c+tvvv8o1xWIG2tFEP3XNAv50vfA1ZH8UzO5fMHUwPLhRMdvT0SNINF
              P5b9syVSF5gXuUzXbNXBgBTO/s1BlV1Obtp5xYc2wDiZMJ10zACntPldwZ3ucUgV
              TFwqmLDMZC9+nwj91DkfUipQeebs43gT087BHDSlR5EFor1CvblIu/iHxIcTRwZy
              h4TDve81AyYMHSEPfBQVu2q5ZeLkDsUPH3NE7x+v13hAjtmWHeo0b1yneGvG0b1b
              yi3aqkNHYT0FST+SebmDJzibvgUE+Vf1l0yKPaECAwEAATANBgkqhkiG9w0BAQsF
              AAOCAQEAGuJCVwrdFsoTqWov5QgattUAD0kv/QJHIbXKwqUfpjETkTf2akDiw4HU
              xoqcwYvmlg5eEwaGnNBh/kbJQapgTEaNQS47bX599sOIDqrVDY7lsEAaHeJsZ6Ux
              pRq3Yis2eyFqXlqZhhzenXHbDrJ01ix7Fo7cFIh9fiocwdCPgKWGATInIWirx5Jz
              hFbtZwj+HWRPWTlpx6QkRxSo5a7nwuhY+2SMUdPnw0iX8C3ra2qjkjE2peYD89FI
              T4ZZHw0Hpp8SnrNtFFk1I1SgFcof9NrwbJYryftSS9xfb7VgH39xn00sRRb+hLcp
              lWp3rha05LxtwOF344A24oxupH06DA==
              -----END CERTIFICATE-----
          user_management:
            provider: local
            local:
              users:
                - name: admin
                  password: admin
                - name: hm
                  password: hm-password
        hm:
          director_account:
            user: hm
            password: hm-password
          resurrector_enabled: true

        google: &google_properties
          project: <%=project_id %>

        agent:
          mbus: nats://nats:nats-password@10.0.0.6:4222
          ntp: *ntp
          blobstore:
             options:
               endpoint: http://10.0.0.6:25250
               user: agent
               password: agent-password

        ntp: &ntp
          - 169.254.169.254

  cloud_provider:
    template:
      name: google_cpi
      release: bosh-google-cpi

    mbus: https://mbus:mbus-password@10.0.0.6:6868

    properties:
      google: *google_properties
      agent: {mbus: "https://mbus:mbus-password@0.0.0.0:6868"}
      blobstore: {provider: local, path: /var/vcap/micro_bosh/data/cache}
      ntp: *ntp
  ```

1. Confirm that `bosh` is installed by querying its version:

  ```
  bosh -v # == 2.x.y
  ```

  This is using the updated bosh-cli V2. When viewing docs written against
  the V1 CLI or bosh-init, use [this reference](https://bosh.io/docs/cli-v2-diff.html)
  to translate between commands.

1. Fill in the template values of the manifest with your environment variables:
  ```
  erb manifest.yml.erb > manifest.yml
  ```

1. Deploy the new manifest to create a BOSH Director:

  ```
  bosh create-env manifest.yml
  ```

1. Download [cert.pem](cert.pem) from this repository.

1. Create an alias for your BOSH environment:

  ```
  bosh alias-env concourse-env --environment 10.0.0.6 --ca-cert cert.pem
  ```

Your username is `admin` and password is `admin`.

### Deploy Concourse
Complete the following steps from your bastion instance.

1. Upload the required [Google BOSH Stemcell](http://bosh.io/docs/stemcell.html):

  ```
  bosh -e concourse-env upload-stemcell https://bosh.io/d/stemcells/bosh-google-kvm-ubuntu-trusty-go_agent?v=3421.11
  ```

1. Upload the required [BOSH Releases](http://bosh.io/docs/release.html):

  ```
  bosh -e concourse-env upload-stemcell https://bosh.io/d/github.com/concourse/concourse?v=2.7.6
  bosh -e concourse-env upload-stemcell https://bosh.io/d/github.com/cloudfoundry/garden-runc-release?v=1.9.0
  ```

1. Download the [cloud-config.yml](cloud-config.yml) manifest file.

1. Download the [concourse.yml](concourse.yml) manifest file and set a few environment variables:

  ```
  export external_ip=`gcloud compute addresses describe concourse | grep ^address: | cut -f2 -d' '`
  export director_uuid=`bosh status --uuid 2>/dev/null`
  ```

1. Chose unique passwords for internal services and ATC and export them
   ```
   export common_password=
   export atc_password=
   ```

1. (Optional) Enable https support for concourse atc

  In `concourse.yml` under the atc properties block fill in the following fields:
  ```
  tls_bind_port: 443
  tls_cert: << SSL Cert for HTTPS >>
  tls_key: << SSL Private Key >>
  ```

  Self-signed credentials can be generated using
  ```
  openssl ecparam -genkey -name prime256v1 -out key.pem
  openssl req -new -sha256 -key key.pem -out csr.csr
  openssl req -x509 -sha256 -days 365 -key key.pem -in csr.csr -out certificate.pem
  ```

  TODO: mention external change

1. Upload the cloud config:

  ```
  bosh update cloud-config cloud-config.yml
  ```

1. Target the deployment file and deploy:

  ```
  bosh deployment concourse.yml
  bosh deploy
  ```
