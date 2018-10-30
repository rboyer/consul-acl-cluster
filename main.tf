provider "docker" {
   version = "1.1.0"
   host = "unix:///var/run/docker.sock"
}

variable "legacy_image" {
  default = "consul:1.3.0"
}

variable "acl_image" {
  default = "consul-dev"
}

variable "legacy_config" {
  default = "acl-legacy.json"
}

variable "acl_config" {
  default = "acl.json"
}

variable "primary_srv1_legacy" {
  default = false
}

variable "primary_srv2_legacy" {
  default = false
}

variable "primary_srv3_legacy" {
  default = false
}

variable "primary_ui_legacy" {
  default = true
}

variable "enable_secondary" {
  default = false
}

variable "secondary_srv1_legacy" {
  default = false
}

variable "secondary_srv2_legacy" {
  default = false
}

variable "secondary_srv3_legacy" {
  default = false
}

variable "secondary_client1_legacy" {
  default = false
}

variable "secondary_client2_legacy" {
  default = false
}

variable "secondary_ui_legacy" {
  default = false
}

variable "server_labels" {
  type = "map"
  default = {
    "consul.cluster.nodetype" = "server"
  }
}

variable "client_labels" {
  type = "map"
  default = {
    "consul.cluster.nodetype" = "client"
  }
}

resource "docker_network" "consul-acls-test" {
  name = "consul-acls-test"
  check_duplicate = "true"
  driver = "bridge"
  options = {
    "com.docker.network.bridge.enable_icc" = "true"
    "com.docker.network.bridge.enable_ip_masquerade" = "true"
  }
  internal = false
}

resource "docker_volume" "consul-primary-srv1-data" {
  name = "consul-primary-srv1-data"
}

resource "docker_container" "consul-primary-srv1" {
  privileged = true
  image = "${var.primary_srv1_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-primary-srv1"
  hostname = "consul-primary-srv1"
  labels = "${var.server_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=primary", "-server", "-client=0.0.0.0", "-bootstrap-expect=3", "-retry-join=consul-primary-srv2", "-retry-join=consul-primary-srv3"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.primary_srv1_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.primary_srv1_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-primary-srv1-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 8501
  }
}

resource "docker_volume" "consul-primary-srv2-data" {
  name = "consul-primary-srv2-data"
}
resource "docker_container" "consul-primary-srv2" {
  privileged = true
  image = "${var.primary_srv2_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-primary-srv2"
  hostname = "consul-primary-srv2"
  labels = "${var.server_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=primary", "-server", "-client=0.0.0.0", "-bootstrap-expect=3", "-retry-join=consul-primary-srv1", "-retry-join=consul-primary-srv3"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.primary_srv2_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.primary_srv2_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-primary-srv2-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 8502
  }
}

resource "docker_volume" "consul-primary-srv3-data" {
  name = "consul-primary-srv3-data"
}

resource "docker_container" "consul-primary-srv3" {
  privileged = true
  image = "${var.primary_srv3_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-primary-srv3"
  hostname = "consul-primary-srv3"
  labels = "${var.server_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=primary", "-server", "-client=0.0.0.0", "-bootstrap-expect=3", "-retry-join=consul-primary-srv1", "-retry-join=consul-primary-srv2"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.primary_srv3_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.primary_srv3_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-primary-srv3-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 8503
  }
}

resource "docker_volume" "consul-primary-ui-data" {
  name = "consul-primary-ui-data"
}

resource "docker_container" "consul-primary-ui" {
    privileged = true
    image = "${var.primary_ui_legacy ? var.legacy_image : var.acl_image}"
    name = "consul-primary-ui"
    hostname = "consul-primary-ui"
    labels = "${var.client_labels}"
    networks = ["consul-acls-test"]
    command = ["agent", "-datacenter=primary", "-client=0.0.0.0", "-retry-join=consul-primary-srv1", "-retry-join=consul-primary-srv2", "-retry-join=consul-primary-srv3", "-ui"]
    env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

    upload {
      content = "${file("${var.primary_ui_legacy ? var.legacy_config : var.acl_config}")}"
      file = "/consul/config/${var.primary_ui_legacy ? var.legacy_config : var.acl_config}"
    }

    volumes {
    volume_name = "${docker_volume.consul-primary-ui-data.name}"
    container_path = "/consul/data"
  }

    ports {
      internal = 8500
      external = 8504
    }
}


resource "docker_volume" "consul-secondary-srv1-data" {
  count = "${var.enable_secondary ? 1 : 0 }"
  name = "consul-secondary-srv1-data"
}

resource "docker_container" "consul-secondary-srv1" {
  count = "${var.enable_secondary ? 1 : 0 }"
  privileged = true
  image = "${var.secondary_srv1_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-secondary-srv1"
  hostname = "consul-secondary-srv1"
  labels = "${var.server_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=secondary", "-server", "-client=0.0.0.0", "-bootstrap-expect=3", "-retry-join=consul-secondary-srv2", "-retry-join=consul-secondary-srv3", "-retry-join-wan=consul-primary-srv1", "-retry-join-wan=consul-primary-srv2", "-retry-join-wan=consul-primary-srv3"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.secondary_srv1_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.secondary_srv1_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-secondary-srv1-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 9501
  }
}

resource "docker_volume" "consul-secondary-srv2-data" {
  count = "${var.enable_secondary ? 1 : 0 }"
  name = "consul-secondary-srv2-data"
}

resource "docker_container" "consul-secondary-srv2" {
  count = "${var.enable_secondary ? 1 : 0 }"
  privileged = true
  image = "${var.secondary_srv2_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-secondary-srv2"
  hostname = "consul-secondary-srv2"
  labels = "${var.server_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=secondary", "-server", "-client=0.0.0.0", "-bootstrap-expect=3", "-retry-join=consul-secondary-srv1", "-retry-join=consul-secondary-srv3", "-retry-join-wan=consul-primary-srv1", "-retry-join-wan=consul-primary-srv2", "-retry-join-wan=consul-primary-srv3"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.secondary_srv2_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.secondary_srv2_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-secondary-srv2-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 9502
  }
}

resource "docker_volume" "consul-secondary-srv3-data" {
  count = "${var.enable_secondary ? 1 : 0 }"
  name = "consul-secondary-srv3-data"
}

resource "docker_container" "consul-secondary-srv3" {
  count = "${var.enable_secondary ? 1 : 0 }"
  privileged = true
  image = "${var.secondary_srv3_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-secondary-srv3"
  hostname = "consul-secondary-srv3"
  labels = "${var.server_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=secondary", "-server", "-client=0.0.0.0", "-bootstrap-expect=3", "-retry-join=consul-secondary-srv1", "-retry-join=consul-secondary-srv2", "-retry-join-wan=consul-primary-srv1", "-retry-join-wan=consul-primary-srv2", "-retry-join-wan=consul-primary-srv3"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.secondary_srv3_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.secondary_srv3_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-secondary-srv3-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 9503
  }
}

resource "docker_volume" "consul-secondary-client1-data" {
  count = "${var.enable_secondary ? 1 : 0 }"
  name = "consul-secondary-client1-data"
}

resource "docker_container" "consul-secondary-client1" {
  count = "${var.enable_secondary ? 1 : 0 }"
  privileged = true
  image = "${var.secondary_client1_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-secondary-client1"
  hostname = "consul-secondary-client1"
  labels = "${var.client_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=secondary", "-client=0.0.0.0", "-retry-join=consul-secondary-srv1", "-retry-join=consul-secondary-srv2", "-retry-join=consul-secondary-srv3"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.secondary_client1_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.secondary_client1_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-secondary-client1-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 9504
  }
}

resource "docker_volume" "consul-secondary-client2-data" {
  count = "${var.enable_secondary ? 1 : 0 }"
  name = "consul-secondary-client2-data"
}

resource "docker_container" "consul-secondary-client2" {
  count = "${var.enable_secondary ? 1 : 0 }"
  privileged = true
  image = "${var.secondary_client2_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-secondary-client2"
  hostname = "consul-secondary-client2"
  labels = "${var.client_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=secondary", "-client=0.0.0.0", "-retry-join=consul-secondary-srv1", "-retry-join=consul-secondary-srv2", "-retry-join=consul-secondary-srv3", "-ui"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.secondary_client2_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.secondary_client2_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
    volume_name = "${docker_volume.consul-secondary-client2-data.name}"
    container_path = "/consul/data"
  }

  ports {
    internal = 8500
    external = 9505
  }
}

resource "docker_volume" "consul-secondary-ui-data" {
  count = "${var.enable_secondary ? 1 : 0 }"
  name = "consul-secondary-ui-data"
}


resource "docker_container" "consul-secondary-ui" {
  count = "${var.enable_secondary ? 1 : 0 }"
  privileged = true
  image = "${var.secondary_ui_legacy ? var.legacy_image : var.acl_image}"
  name = "consul-secondary-ui"
  hostname = "consul-secondary-ui"
  labels = "${var.client_labels}"
  networks = ["consul-acls-test"]
  command = ["agent", "-datacenter=secondary", "-client=0.0.0.0", "-retry-join=consul-secondary-srv1", "-retry-join=consul-secondary-srv2", "-retry-join=consul-secondary-srv3", "-ui"]
  env=["CONSUL_BIND_INTERFACE=eth0", "CONSUL_ALLOW_PRIVILEGED_PORTS=yes"]

  upload {
    content = "${file("${var.secondary_ui_legacy ? var.legacy_config : var.acl_config}")}"
    file = "/consul/config/${var.secondary_ui_legacy ? var.legacy_config : var.acl_config}"
  }

  volumes {
  volume_name = "${docker_volume.consul-secondary-ui-data.name}"
  container_path = "/consul/data"
}

  ports {
    internal = 8500
    external = 9506
  }
}
