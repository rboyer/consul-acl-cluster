variable "legacy_image" {
  # default = "consul:1.3.0"
  default = "consul-dev:ent-1.3"
}

variable "acl_image" {
  # default = "consul-dev:latest"
  default = "consul-dev:ent-1.4-b9"
}

variable "legacy_config" {
  default = "config-old"
}

variable "acl_config" {
  default = "config-new"
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
