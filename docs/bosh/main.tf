// Easier maintenance for updating GCE image string
variable "latest_ubuntu" {
    type = "string"
    default = "ubuntu-1404-trusty-v20170505"
}

variable "project_id" {
    type = "string"
}

variable "network_project_id" {
    type = "string"
}

variable "region" {
    type = "string"
    default = "us-east1"
}

variable "zone" {
    type = "string"
    default = "us-east1-d"
}

variable "prefix" {
    type = "string"
    default = ""
}

variable "service_account_email" {
    type = "string"
    default = ""
}

variable "baseip" {
    type = "string"
    default = "10.0.0.0"
}

provider "google" {
    project = "${var.project_id}"
    region = "${var.region}"
}

resource "google_compute_network" "bosh" {
  name       = "${var.prefix}bosh"
  project    = "${var.network_project_id}"
}

resource "google_compute_route" "nat-primary" {
  name                   = "${var.prefix}nat-primary"
  dest_range             = "0.0.0.0/0"
  network                = "${google_compute_network.bosh.name}"
  next_hop_instance      = "${google_compute_instance.nat-instance-private-with-nat-primary.name}"
  next_hop_instance_zone = "${var.zone}"
  priority               = 800
  tags                   = ["no-ip"]
  project                = "${var.network_project_id}"
}

// Subnet for the BOSH director
resource "google_compute_subnetwork" "bosh-subnet-1" {
  name          = "${var.prefix}bosh-${var.region}"
  ip_cidr_range = "${var.baseip}/24"
  network       = "${google_compute_network.bosh.self_link}"
  project       = "${var.network_project_id}"
}

// Allow SSH to BOSH bastion
resource "google_compute_firewall" "bosh-bastion" {
  name    = "${var.prefix}bosh-bastion"
  network = "${google_compute_network.bosh.name}"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["bosh-bastion"]
  project     = "${var.network_project_id}"
}

// Allow all traffic within subnet
resource "google_compute_firewall" "intra-subnet-open" {
  name    = "${var.prefix}intra-subnet-open"
  network = "${google_compute_network.bosh.name}"
  project = "${var.network_project_id}"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["1-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["1-65535"]
  }

  source_tags = ["internal"]
}

// BOSH bastion host
resource "google_compute_instance" "bosh-bastion" {
  name         = "${var.prefix}bosh-bastion"
  machine_type = "n1-standard-1"
  zone         = "${var.zone}"

  tags = ["bosh-bastion", "internal"]

  disk {
    image = "${var.latest_ubuntu}"
  }

  network_interface {
    subnetwork         = "${google_compute_subnetwork.bosh-subnet-1.name}"
    subnetwork_project = "${var.network_project_id}"
    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = <<EOT
#!/bin/bash
cat > /etc/motd <<EOF




#    #     ##     #####    #    #   #   #    #    ####
#    #    #  #    #    #   ##   #   #   ##   #   #    #
#    #   #    #   #    #   # #  #   #   # #  #   #
# ## #   ######   #####    #  # #   #   #  # #   #  ###
##  ##   #    #   #   #    #   ##   #   #   ##   #    #
#    #   #    #   #    #   #    #   #   #    #    ####

Startup scripts have not finished running, and the tools you need
are not ready yet. Please log out and log back in again in a few moments.
This warning will not appear when the system is ready.
EOF

apt-get update
apt-get install -y build-essential zlibc zlib1g-dev ruby ruby-dev openssl libxslt-dev libxml2-dev libssl-dev libreadline6 libreadline6-dev libyaml-dev libsqlite3-dev sqlite3 git unzip
gem install bosh_cli
curl -L -o /tmp/cf.tgz "https://cli.run.pivotal.io/stable?release=linux64-binary&version=6.28.0&source=github-rel"
tar -zxvf /tmp/cf.tgz && mv cf /usr/bin/cf && chmod +x /usr/bin/cf
curl -o /usr/bin/bosh-init https://s3.amazonaws.com/bosh-init-artifacts/bosh-init-0.0.96-linux-amd64
chmod +x /usr/bin/bosh-init
curl -o /usr/bin/bosh2 https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.28-linux-amd64
chmod +x /usr/bin/bosh2
curl -L -o /usr/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
chmod +x /usr/bin/jq

cat > /etc/profile.d/bosh.sh <<'EOF'
#!/bin/bash
# Misc vars
export prefix=${var.prefix}
export ssh_key_path=$HOME/.ssh/bosh

# Vars from Terraform
export subnetwork=${google_compute_subnetwork.bosh-subnet-1.name}
export network=${google_compute_network.bosh.name}
export network_project_id=${var.network_project_id}


# Vars from metadata service
export project_id=$$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
export zone=$$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone)
export zone=$${zone##*/}
export region=$${zone%-*}

# Configure gcloud
gcloud config set compute/zone $${zone}
gcloud config set compute/region $${region}
EOF

# Clone repo
mkdir /share
git clone https://github.com/cloudfoundry-incubator/bosh-google-cpi-release.git /share
chmod -R 777 /share

# Install Terraform
wget https://releases.hashicorp.com/terraform/0.7.7/terraform_0.7.7_linux_amd64.zip
unzip terraform*.zip -d /usr/local/bin
rm /etc/motd
EOT

  service_account {
    email = "${var.service_account_email}"
    scopes = ["cloud-platform"]
  }
}

// NAT server (primary)
resource "google_compute_instance" "nat-instance-private-with-nat-primary" {
  name         = "${var.prefix}nat-instance-primary"
  machine_type = "n1-standard-1"
  zone         = "${var.zone}"
  project      = "${var.network_project_id}"

  tags = ["nat", "internal"]

  disk {
    image = "${var.latest_ubuntu}"
  }

  network_interface {
    subnetwork = "${google_compute_subnetwork.bosh-subnet-1.name}"
    subnetwork_project = "${var.network_project_id}"
    access_config {
      // Ephemeral IP
    }
  }

  can_ip_forward = true

  metadata_startup_script = <<EOT
#!/bin/bash
sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
EOT
}
