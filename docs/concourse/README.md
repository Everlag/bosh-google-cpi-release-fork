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
              -----BEGIN EC PARAMETERS-----
              BggqhkjOPQMBBw==
              -----END EC PARAMETERS-----
              -----BEGIN EC PRIVATE KEY-----
              MHcCAQEEIFTa2BiKaUKEHWkNLGpWvzCUvoVbO9FI8omOyOSJB0RboAoGCCqGSM49
              AwEHoUQDQgAE5iS6HfZCFh2tUfg/16cMjib1WyBPsRu2BMqUBohxoZET0GfOcFcL
              JKfYLEZi+WD4Dulyy1m/eDu6HuUH8+FWqA==
              -----END EC PRIVATE KEY-----
            cert: |
              -----BEGIN CERTIFICATE-----
              MIIB4TCCAYigAwIBAgIJANUkEjFsA6EiMAoGCCqGSM49BAMCMEUxCzAJBgNVBAYT
              AkFVMRMwEQYDVQQIDApTb21lLVN0YXRlMSEwHwYDVQQKDBhJbnRlcm5ldCBXaWRn
              aXRzIFB0eSBMdGQwHhcNMTcwNzE5MjA0NDU4WhcNMjAwNTA4MjA0NDU4WjBFMQsw
              CQYDVQQGEwJBVTETMBEGA1UECAwKU29tZS1TdGF0ZTEhMB8GA1UECgwYSW50ZXJu
              ZXQgV2lkZ2l0cyBQdHkgTHRkMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE5iS6
              HfZCFh2tUfg/16cMjib1WyBPsRu2BMqUBohxoZET0GfOcFcLJKfYLEZi+WD4Duly
              y1m/eDu6HuUH8+FWqKNhMF8wHQYDVR0OBBYEFH09+ToXsipFFglNsBPFei3SmEdX
              MB8GA1UdIwQYMBaAFH09+ToXsipFFglNsBPFei3SmEdXMAwGA1UdEwQFMAMBAf8w
              DwYDVR0RBAgwBocECgAABjAKBggqhkjOPQQDAgNHADBEAiB7Cq0EM86/JaSsYcNO
              TyWqsxGJZG9PGkRhu+5w/sGuGgIgLqHdjrrXKPMUBb5e7Vp8Q8pPf2NraoHYqkRI
              qQktWnw=
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

1. Choose unique passwords for internal services and ATC and export them
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

  Modify `concourse.yml` to use an HTTPS url using sed:
  ```
  sed -i 's|external_url = "http://|external_url = "https://|g' concourse.yml
  ```

  Self-signed credentials can be generated using
  ```
  openssl ecparam -genkey -name prime256v1 -out key.pem
  openssl req -new -sha256 -key key.pem -out csr.csr
  openssl req -x509 -sha256 -days 1460 -key key.pem -in csr.csr -out certificate.pem
  ```

1. Upload the cloud config:

  ```
  bosh -e concourse-env update-cloud-config cloud-config.yml
  ```

1. Create the new deployment with the deployment file:

  ```
  bosh --environment concourse-env --deployment concourse-deployment deploy concourse.yml
  ```
