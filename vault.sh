#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

MASTER_TOKEN=""
VAULT_SECRET_TOKEN=""
VAULT_STORE_TOKEN=""

die() {
    echo "ERROR: $1" >&2
    exit 1
}
check_idfile() {
    local name="$1"
    local type="$2"

    local fn="tmp/${name}_${type}.json"
    if [[ ! -f "$fn" ]]; then
        die "missing ${name} ${type} file: ${fn}"
    fi
    if [[ ! -s "$fn" ]]; then
        rm -f "${fn}"
        die "empty ${name} ${type} file (now erased): ${fn}"
    fi
    if ! < "$fn" jq '.ID, .SecretID' >/dev/null 2>&1 ; then
        die "bad ${name} ${type} file: ${fn}"
    fi
}
load_idfile() {
    local name="$1"
    local type="$2"
    if [[ "${1:-}" != "check" ]]; then
        check_idfile "$name" "$type"
    fi

    local fn="tmp/${name}_${type}.json"

    local token=""
    token="$(jq -r .ID < "$fn")"
    echo "$token"
}
load_master_token() {
    local token
    token="$(load_idfile master token)"
    if [[ "${MASTER_TOKEN}" != "${token}" ]]; then
        MASTER_TOKEN="${token}"
        echo "Master Token is ${MASTER_TOKEN}"
    fi
}
load_vault_tokens() {
    local token
    token="$(load_idfile vaultsecret token)"
    if [[ "${VAULT_SECRET_TOKEN}" != "${token}" ]]; then
        VAULT_SECRET_TOKEN="${token}"
        echo "Vault Secret Token is ${VAULT_SECRET_TOKEN}"
    fi

    token="$(load_idfile vaultstore token)"
    if [[ "${VAULT_STORE_TOKEN}" != "${token}" ]]; then
        VAULT_STORE_TOKEN="${token}"
        echo "Vault Store Token is ${VAULT_STORE_TOKEN}"
    fi
}


load_master_token
load_vault_tokens

export CONSUL_HTTP_TOKEN="${MASTER_TOKEN}"

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=3lWWQRk9wsODR0AtprvZj84T

policy='key "" { policy = "read" }'
policy_enc="$(echo -n "${policy}" | base64)"

echo ">>>>>>>>>>>>>>>>"
echo "export VAULT_ADDR=${VAULT_ADDR}"
echo "export VAULT_TOKEN=${VAULT_TOKEN}"
echo "vault secrets enable consul"
echo "vault write consul/config/access address=127.0.0.1:8501 token=${VAULT_SECRET_TOKEN}"
echo "vault write consul/roles/my-role policy=${policy_enc}"
echo "<<<<<<<<<<<<<<<<"

exec vault read consul/creds/my-role
