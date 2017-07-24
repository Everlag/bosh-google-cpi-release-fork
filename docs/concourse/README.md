# Deploying Concourse on Google Compute Engine

This guide describes how to deploy [Concourse](http://concourse.ci/) on [Google Compute Engine](https://cloud.google.com/) using BOSH. The BOSH director must have been created following the steps in the [Deploy BOSH on Google Cloud Platform](../bosh/README.md) guide.

## Prerequisites

* You must have an existing BOSH director and bastion host created by following the [Deploy BOSH on Google Cloud Platform](../bosh/README.md) guide.


### Steps to perform in `bosh-bastion`
Complete the following steps from your bastion instance.

1. SSH to the `bosh-bastion` VM. You can SSH form Cloud Shell or any workstation that has `gcloud` installed:

    ```
    gcloud compute ssh bosh-bastion
    ```

1. `cd` into the Concourse docs directory that you cloned when you created the BOSH bastion:

    ```
    cd /share/docs/concourse
    ```

1. Export a few vars to specify the location of concourse VMs:

    ```
    export region=us-east1
    ```

1. View the Terraform execution plan to see the resources that will be created:

    ```
    terraform plan \
      -var project_id=${project_id}\
      -var region=${region} \
      -var zone-1=${zone} \
      -var zone-2=${zone2}
    ```

1. Create the resources:

    ```
    terraform apply \
      -var project_id=${project_id}\
      -var region=${region} \
      -var zone-1=${zone} \
      -var zone-2=${zone2}
    ```

1. Target and login into your BOSH environment:

    ```
    bosh2 alias-env my-bosh-env --environment 10.0.0.6 --ca-cert ../ca_cert.pem
    bosh2 login -e my-bosh-env
    ```

    > **Note:** Your username is `admin` and password is `admin`.

1. Upload the required [Google BOSH Stemcell](http://bosh.io/docs/stemcell.html):

  ```
  bosh2 -e my-bosh-env upload-stemcell https://bosh.io/d/stemcells/bosh-google-kvm-ubuntu-trusty-go_agent?v=3421.11
  ```

1. Upload the required [BOSH Releases](http://bosh.io/docs/release.html):

  ```
  bosh2 -e my-bosh-env upload-release https://bosh.io/d/github.com/concourse/concourse?v=2.7.6
  bosh2 -e my-bosh-env upload-release https://bosh.io/d/github.com/cloudfoundry/garden-runc-release?v=1.9.0
  ```

1. Export a few vars to configure the deployment in [manifest.yml.erb](manifest.yml.erb):

  ```
  export external_ip=`gcloud compute addresses describe concourse | grep ^address: | cut -f2 -d' '`
  export director=$(bosh2 env -e my-bosh-env | sed -n 2p)

  ```

1. Choose unique passwords for internal services and ATC and export them
   ```
   export common_password=
   export atc_password=
   ```

1. (Optional) Enable https support for concourse atc

  In `manifest.yml.erb` under the atc properties block fill in the following fields:
  ```
  tls_bind_port: 443
  tls_cert: |
    << SSL Cert for HTTPS >>
  tls_key: |
    << SSL Private Key >>
  ```

  Modify `manifest.yml.erb` to use an HTTPS url using sed:
  ```
  sed -i 's|external_url = "http://|external_url = "https://|g' manifest.yml.erb
  ```

  Self-signed credentials can be generated using
  ```
  openssl ecparam -genkey -name prime256v1 -out key.pem
  openssl req -new -sha256 -key key.pem -out csr.csr
  openssl req -x509 -sha256 -days 1460 -key key.pem -in csr.csr -out certificate.pem
  ```

1. Use `erb` to substitute variables in the template:

    ```
    erb manifest.yml.erb > manifest.yml
    ```

1. Upload the cloud config:

  ```
  bosh2 -e my-bosh-env update-cloud-config cloud-config.yml
  ```

1. Create the new deployment with the deployment file:

  ```
  bosh2 --environment my-bosh-env --deployment concourse deploy manifest.yml
  ```

### Delete resources

From your `bosh-bastion` instance, delete your Concourse deployment:

  ```
  TODO: test
  bosh2 -e my-bosh-env delete-deployment -d concourse
  ```

Then delete the infrastructure you created with terraform:
  ```
  cd /share/docs/concourse
  terraform destroy \
    -var network=${network} \
    -var project_id=${project_id} \
    -var region=${region}
  ```

**Important:** The BOSH bastion and director you created must also be destroyed. Follow the **Delete resources** instructions in the [Deploy BOSH on Google Cloud Platform](../bosh/README.md) guide.
