#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/tasks/utils.sh
source /etc/profile.d/chruby-with-ruby-2.1.2.sh

check_param google_project
check_param google_region
check_param google_zone
check_param google_json_key_data
check_param google_network
check_param google_subnetwork
check_param google_subnetwork_range
check_param google_subnetwork_gw
check_param google_firewall_internal
check_param google_firewall_external
check_param google_address_director
check_param google_address_static_director
check_param private_key_user
check_param private_key_data
check_param director_password
check_param director_username

deployment_dir="${PWD}/deployment"
cpi_release_name=bosh-google-cpi
google_json_key=${deployment_dir}/google_key.json
private_key=${deployment_dir}/private_key.pem
manifest_filename="director-manifest.yml"

echo "Setting up artifacts..."
cp ./bosh-cpi-release/*.tgz ${deployment_dir}/${cpi_release_name}.tgz
cp ./bosh-release/*.tgz ${deployment_dir}/bosh-release.tgz
cp ./stemcell/*.tgz ${deployment_dir}/stemcell.tgz

# Overwrite with our custom bosh release
# TODO: REMOVE when we are PRing
gsutil cp gs://bosh-gcs-testingboshrelease/bosh-devrelease.tgz \
  ${deployment_dir}/bosh-release.tgz

echo "Creating google json key..."
echo "${google_json_key_data}" > ${google_json_key}
mkdir -p $HOME/.config/gcloud/
cp ${google_json_key} $HOME/.config/gcloud/application_default_credentials.json

echo "Configuring google account..."
gcloud auth activate-service-account --key-file $HOME/.config/gcloud/application_default_credentials.json
gcloud config set project ${google_project}
gcloud config set compute/region ${google_region}
gcloud config set compute/zone ${google_zone}

echo "Looking for director IP..."
director_ip=$(gcloud compute addresses describe ${google_address_director} --format json | jq -r '.address')

echo "Creating private key..."
echo "${private_key_data}" > ${private_key}
chmod go-r ${private_key}
eval $(ssh-agent)
ssh-add ${private_key}

echo "Creating ${manifest_filename}..."
cat > "${deployment_dir}/${manifest_filename}"<<EOF
---
name: bosh
releases:
  - name: bosh
    url: file://bosh-release.tgz
  - name: ${cpi_release_name}
    url: file://${cpi_release_name}.tgz

resource_pools:
  - name: vms
    network: private
    stemcell:
      # url: file://stemcell.tgz
      url: https://s3.amazonaws.com/bosh-core-stemcells/google/bosh-stemcell-3312.15-google-kvm-ubuntu-trusty-go_agent.tgz
      sha1: 3e00695743f1be7119f032ce5264e335e95732bf
    cloud_properties:
      zone: ${google_zone}
      machine_type: n1-standard-2
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
  - name: private
    type: manual
    subnets:
    - range: ${google_subnetwork_range}
      gateway: ${google_subnetwork_gw}
      cloud_properties:
        network_name: ${google_network}
        subnetwork_name: ${google_subnetwork}
        tags:
          - ${google_firewall_internal}
          - ${google_firewall_external}
  - name: public
    type: vip

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
      - name: registry
        release: bosh
      - name: google_cpi
        release: bosh-google-cpi

    resource_pool: vms
    persistent_disk_pool: disks

    networks:
      - name: private
        static_ips: [${google_address_static_director}]
        default:
          - dns
          - gateway
      - name: public
        static_ips:
          - ${director_ip}

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
        address: ${google_address_static_director}
        domain_name: microbosh
        db: *db
        recursor: 169.254.169.254

      registry:
        address: ${google_address_static_director}
        host: ${google_address_static_director}
        db: *db
        http:
          user: registry
          password: registry-password
          port: 25777
        username: registry
        password: registry-password
        port: 25777

      blobstore:
        address: ${google_address_static_director}
        port: 25250
        # provider: dav
        provider: gcs
        bucket_name: bosh-gcs-blobstore-test
        credentials_source: static
        json_key: |
          $(echo $google_json_key_data | tr -d '\n')
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
              - name: ${director_username}
                password: ${director_password}
              - name: hm
                password: hm-password
      hm:
        director_account:
          user: hm
          password: hm-password
        resurrector_enabled: true

      google: &google_properties
        project: ${google_project}

      agent:
        mbus: nats://nats:nats-password@${google_address_static_director}:4222
        ntp: *ntp
        blobstore:
           options:
             endpoint: http://${google_address_static_director}:25250
             user: agent
             password: agent-password

      ntp: &ntp
        - 169.254.169.254

cloud_provider:
  template:
    name: google_cpi
    release: bosh-google-cpi

  mbus: https://mbus:mbus-password@${director_ip}:6868

  properties:
    google: *google_properties
    agent: {mbus: "https://mbus:mbus-password@0.0.0.0:6868"}
    blobstore: {provider: local, path: /var/vcap/micro_bosh/data/cache}
    ntp: *ntp
EOF

pushd ${deployment_dir}
  function finish {
    echo "Final state of director deployment:"
    echo "=========================================="
    cat director-manifest-state.json
    echo "=========================================="

    cp -r $HOME/.bosh_init ./
  }
  trap finish ERR

  chmod +x ../bosh-init/bosh-init*

  echo "Using bosh-init version..."
  ../bosh-init/bosh-init* version

  echo "manifest file is"
  cat ${manifest_filename}

  echo "Deploying BOSH Director..."
  ../bosh-init/bosh-init* deploy ${manifest_filename}

  trap - ERR
  finish
popd
