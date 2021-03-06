#!/usr/bin/env bash

unset CDPATH

set -euo pipefail

cd "$(dirname "$0")"

declare -A primary_nodes
primary_nodes=(
    [consul-primary-srv1]=8501
    [consul-primary-srv2]=8502
    [consul-primary-srv3]=8503
    [consul-primary-ui]=8504
)
pri_sorted=(
    consul-primary-srv1
    consul-primary-srv2
    consul-primary-srv3
    consul-primary-ui
)

declare -A secondary_nodes
secondary_nodes=(
    [consul-secondary-srv1]=9501
    [consul-secondary-srv2]=9502
    [consul-secondary-srv3]=9503
    [consul-secondary-client1]=9504
    [consul-secondary-client2]=9505
    [consul-secondary-ui]=9506
)
sec_sorted=(
    consul-secondary-srv1
    consul-secondary-srv2
    consul-secondary-srv3
    consul-secondary-client1
    consul-secondary-client2
    consul-secondary-ui
)

declare -A all_nodes
for name in "${!primary_nodes[@]}"; do
    port=${primary_nodes[$name]}
    all_nodes[$name]=$port
done
for name in "${!secondary_nodes[@]}"; do
    port=${secondary_nodes[$name]}
    all_nodes[$name]=$port
done
all_sorted=(
    ${pri_sorted[@]}
    ${sec_sorted[@]}
)

mkdir -p tmp config-old config-new

MASTER_TOKEN=""
AGENT_TOKEN=""
AGENT_POLICY=""
REPL_TOKEN=""
VAULT_STORE_TOKEN=""
VAULT_SECRET_TOKEN=""

declare -A UPGRADED_HOSTS

die() {
    echo "ERROR: $1" >&2
    exit 1
}

fixperms() {
    if [[ $# -lt 1 ]]; then
        die "fixperms requires args"
    fi
    # ugh the official docker image rechowns the config dir...
    sudo chown -R $(id -u):$(id -g) "$@"
}

load_upgraded() {
    if [[ ! -f tmp/list.upgraded ]]; then
        UPGRADED_HOSTS=()
        return
    fi
    local hosts
    readarray -t hosts < <(sort tmp/list.upgraded)

    UPGRADED_HOSTS=()
    for h in "${hosts[@]}"; do
        UPGRADED_HOSTS[$h]=1
    done
}
write_upgraded() {
    mkdir -p tmp

    if [[ "${#UPGRADED_HOSTS[@]}" -lt 1 ]]; then
        rm -f tmp/list.upgraded
        return
    fi

    rm -f tmp/list.upgraded.tmp
    for host in "${!UPGRADED_HOSTS[@]}"; do
        echo "${host}" >> tmp/list.upgraded.tmp
    done
    mv -f tmp/list.upgraded.tmp tmp/list.upgraded
}

do_destroy() {
    terraform destroy -auto-approve
    rm -f tmp/*
    rm -f tmp/.*.booted tmp/.*.upgraded

    fixperms config-old config-new
    rm -rf config-old/*
    rm -rf config-new/*
}

restart() {
    restart_primary
    restart_secondary
}

restart_primary() {
    local name
    local url

    echo "Restarting: ${pri_sorted[@]}"
    docker restart "${pri_sorted[@]}"

    for name in "${pri_sorted[@]}"; do
        port=${primary_nodes[$name]}
        url="http://localhost:${port}/v1/status/leader"

        while ! curl -sLf "${url}" >/dev/null 2>&1 ; do
            echo "Still waiting on: ${name}"
        done
    done
}

restart_secondary() {
    local name
    local url

    echo "Restarting: ${sec_sorted[@]}"
    docker restart "${sec_sorted[@]}"

    for name in "${sec_sorted[@]}"; do
        port=${secondary_nodes[$name]}
        url="http://localhost:${port}/v1/status/leader"

        while ! curl -sLf "${url}" >/dev/null 2>&1 ; do
            echo "Still waiting on: ${name}"
        done
    done
}

wait_all() {
    local name
    local port
    local url
    for name in "${all_sorted[@]}"; do
        port=${all_nodes[$name]}
        url="http://localhost:${port}/v1/status/leader"

        while ! curl -sLf "${url}" >/dev/null 2>&1 ; do
            echo "Still waiting on: ${name}"
        done
    done
}

genconfig() {
    local name
    local port

    # populate vars before we generate configs
    load_master_token check >/dev/null 2>&1 || true
    load_agent_token check >/dev/null 2>&1 || true
    load_repl_token check >/dev/null 2>&1 || true

    fixperms config-old config-new

    for name in "${pri_sorted[@]}"; do
        # port=${primary_nodes[$name]}
        genconfig_host "$name" primary
    done

    for name in "${sec_sorted[@]}"; do
        # port=${secondary_nodes[$name]}
        genconfig_host "$name" secondary
    done
}
genconfig_host() {
    local name="$1"
    local flavor="$2"

    local old_dir="config-old/${name}"
    local new_dir="config-new/${name}"

    mkdir -p "${old_dir}" "${new_dir}"

    # main ACL configs
    cat > "${old_dir}/acl.json" <<EOF
{
   "log_level":"debug",
   "acl_datacenter" : "primary",
   "acl_default_policy" : "deny",
   "acl_down_policy": "async-cache"
}
EOF
    cat > "${new_dir}/acl.json" <<EOF
{
  "log_level":"debug",
  "primary_datacenter": "primary",
  "acl": {
    "enabled": true,
    "enable_token_replication": true,
    "default_policy": "deny",
    "down_policy": "async-cache"
  }
}
EOF

    if [[ -n "${ACL_DO_NOT_ENFORCE_VERSION_8}" ]]; then
        cat > "${old_dir}/acl-v8.json" << EOF
{
  "acl_enforce_version_8": false
}
EOF
        cp -f "${old_dir}/acl-v8.json" "${new_dir}/acl-v8.json"
    else
        rm -f "${old_dir}/acl-v8.json"
        rm -f "${new_dir}/acl-v8.json"
        :
    fi

    # drop in for agent auth
    if [[ -n "${AGENT_TOKEN}" ]]; then
        cat > "${old_dir}/acl-agent.json" << EOF
{
  "acl_agent_token":"${AGENT_TOKEN}"
}
EOF
        cat > "${new_dir}/acl-agent.json" << EOF
{
  "acl": {
    "tokens": {
      "agent":"${AGENT_TOKEN}"
    }
  }
}
EOF
    else
        rm -f "${old_dir}/acl-agent.json"
        rm -f "${new_dir}/acl-agent.json"
    fi

    # drop in for replication
    if [[ -n "${REPL_TOKEN}" && "${flavor}" = "secondary" ]]; then
        cat > "${old_dir}/acl-repl.json" << EOF
{
  "acl_replication_token":"${REPL_TOKEN}"
}
EOF
        cat > "${new_dir}/acl-repl.json" << EOF
{
  "acl": {
    "tokens": {
      "replication":"${REPL_TOKEN}"
    }
  }
}
EOF
    else
        rm -f "${old_dir}/acl-repl.json"
        rm -f "${new_dir}/acl-repl.json"
    fi
}

tobool() {
    if [[ -n "${1:-}" ]]; then
        echo true
    else
        echo false
    fi
}
to_inv_bool() {
    if [[ -z "${1:-}" ]]; then
        echo true
    else
        echo false
    fi
}


build() {
    genconfig

    terraform apply -auto-approve \
        -var primary_srv1_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-primary-srv1]:-}) \
        -var primary_srv2_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-primary-srv2]:-}) \
        -var primary_srv3_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-primary-srv3]:-}) \
        -var primary_ui_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-primary-ui]:-}) \
        -var enable_secondary=true \
        -var secondary_srv1_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-secondary-srv1]:-}) \
        -var secondary_srv2_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-secondary-srv2]:-}) \
        -var secondary_srv3_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-secondary-srv3]:-}) \
        -var secondary_ui_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-secondary-ui]:-}) \
        -var secondary_client1_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-secondary-client1]:-}) \
        -var secondary_client2_legacy=$(to_inv_bool ${UPGRADED_HOSTS[consul-secondary-client2]:-})

    wait_all
}

check_token() {
    check_idfile "$1" token
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
    if [[ -n "$USE_SECRETS" ]]; then
        token="$(jq -r .SecretID < "$fn")"
    fi
    if [[ -z "$token" ]]; then
        token="$(jq -r .ID < "$fn")"
    fi
    echo "$token"
}

aclboot_master_old() {
    mkdir -p tmp
    if [[ ! -f tmp/master_token.json ]]; then
        echo "Bootstrapping ACLs..."
        curl -sL -XPUT http://localhost:8501/v1/acl/bootstrap > tmp/master_token.json
        echo "...done"
    fi
    load_master_token
}
load_master_token() {
    local token
    token="$(load_idfile master token)"
    if [[ "${MASTER_TOKEN}" != "${token}" ]]; then
        MASTER_TOKEN="${token}"
        echo "Master Token is ${MASTER_TOKEN}"
    fi
}
aclboot_agent() {
    if [[ -n "$USE_NEW_AGENTAPI" ]]; then
        aclboot_agent_new
    else
        aclboot_agent_old
    fi
}
aclboot_agent_old() {
    load_master_token

    mkdir -p tmp
    if [[ ! -f tmp/agent_token.json ]]; then
        curl -sL -XPUT http://localhost:8501/v1/acl/create \
            -H "X-Consul-Token: ${MASTER_TOKEN}" \
            -d '{
  "Name": "Agent Token",
  "Type": "client",
  "Rules": "agent \"\" { policy = \"write\" } node \"\" { policy = \"write\" } service \"\" { policy = \"read\" }"
}' > tmp/agent_token.json
    fi
    load_agent_token

    # now install
    mkdir -p tmp
    if [[ -f tmp/.agents.booted ]]; then
        return
    fi
    genconfig
    restart
    touch tmp/.agents.booted
}
aclboot_agent_new() {
    load_master_token

    mkdir -p tmp

    # double guard so we can avoid creating a policy we won't use if we
    # start in OLD and then upgrade to NEW
    if [[ ! -f tmp/agent_token.json ]]; then
        # first make the policy
        if [[ ! -f tmp/agent_policy.json ]]; then
            curl -sL -XPUT 'http://localhost:8501/v1/acl/policy' \
                -H "X-Consul-Token: ${MASTER_TOKEN}" \
                -d '{
  "Name" : "agent-default",
  "Description" : "Can register any node and read any service",
  "Rules": "agent_prefix \"\" { policy = \"write\" } node_prefix \"\" { policy = \"write\" } service_prefix \"\" { policy = \"read\" }"
}' > tmp/agent_policy.json
        fi
        load_agent_policy

        # now make the token
            curl -sL -XPUT http://localhost:8501/v1/acl/token \
                -H "X-Consul-Token: ${MASTER_TOKEN}" \
                -d "{
  \"Name\": \"Agent Token\",
  \"Description\": \"Agent Token\",
  \"Policies\" : [ { \"ID\" : \"${AGENT_POLICY}\" } ]
}" > tmp/agent_token.json
    fi
    load_agent_token

    # now install
    mkdir -p tmp
    if [[ -f tmp/.agents.booted ]]; then
        return
    fi
    genconfig
    restart
    touch tmp/.agents.booted
}
load_agent_token() {
    local token
    token="$(load_idfile agent token)"
    if [[ "${AGENT_TOKEN}" != "${token}" ]]; then
        AGENT_TOKEN="${token}"
        echo "Agent Token is ${AGENT_TOKEN}"
    fi
}
load_agent_policy() {
    if [[ "${1:-}" != "check" ]]; then
        check_idfile agent policy
    fi

    local policy
    policy="$(jq -r .ID < tmp/agent_policy.json)"
    if [[ "${AGENT_POLICY}" != "${policy}" ]]; then
        AGENT_POLICY="${policy}"
        echo "Agent Policy is ${AGENT_POLICY}"
    fi
}

aclboot_anon_old() {
    load_master_token

    mkdir -p tmp
    if [[ -f tmp/.anon.booted ]]; then
        return
    fi

    curl -sL -XPUT \
        "http://localhost:8501/v1/acl/update" \
        -H "X-Consul-Token: ${MASTER_TOKEN}" \
        -d '{
"ID": "anonymous",
"Name":"Anonymous",
"Type": "client",
"Rules": "node \"\" { policy = \"read\" }"
}' > /dev/null
    touch tmp/.anon.booted
}

aclboot_repl_old() {
    load_master_token

    # This token must have at least "read" permissions on ACL data but if ACL
    # token replication is enabled then it must have "write" permissions.


    mkdir -p tmp
    if [[ ! -f tmp/repl_token.json ]]; then
        curl -sL -XPUT http://localhost:8501/v1/acl/create \
            -H "X-Consul-Token: ${MASTER_TOKEN}" \
            -d '{
  "Name": "Repl Token",
  "Type": "management"
}' > tmp/repl_token.json
    fi
    load_repl_token

    # now install
    mkdir -p tmp
    if [[ -f tmp/.repl.booted ]]; then
        return
    fi
    genconfig
    restart_secondary
    touch tmp/.repl.booted
}
load_repl_token() {
    local token
    token="$(load_idfile repl token)"
    if [[ "${REPL_TOKEN}" != "${token}" ]]; then
        REPL_TOKEN="${token}"
        echo "Replication Token is ${REPL_TOKEN}"
    fi
}
check_repl() {
    local name
    local url

    echo "Replication status in secondary DC:"
    for name in "${sec_sorted[@]}"; do
        port=${secondary_nodes[$name]}

        url="http://localhost:${port}/v1/acl/replication"

        # curl -sL "${url}" | jq -c "{\"node\":\"${name}\", \"enabled\":.Enabled,\"running\":.Running}"
        curl -sL "${url}" | jq . #-c "{\"node\":\"${name}\", \"enabled\":.Enabled,\"running\":.Running}"
    done
}

aclboot_vault_old() {
    load_master_token

    mkdir -p tmp

    if [[ ! -f tmp/vaultsecret_token.json ]]; then
        curl -sL -XPUT http://localhost:8501/v1/acl/create \
            -H "X-Consul-Token: ${MASTER_TOKEN}" \
            -d '{
  "Name": "Vault Secret Token",
  "Type": "management"
}' > tmp/vaultsecret_token.json
    fi

    if [[ ! -f tmp/vaultstore_token.json ]]; then
        local write='{ policy = \"write\" }'
        curl -sL -XPUT http://localhost:8501/v1/acl/create \
            -H "X-Consul-Token: ${MASTER_TOKEN}" \
            -d '{
  "Name": "Vault Storage Token",
  "Type": "client",
  "Rules": "key \"vault/\" { policy = \"write\" } node \"\" { policy = \"write\" } service \"vault\" { policy = \"write\" } agent \"\" { policy = \"write\" } session \"\" { policy = \"write\" }"
}' > tmp/vaultstore_token.json
    fi

    load_vault_tokens
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

do_refresh() {
    # set -x
    # genconfig
    # restart
    build
    # exit 0

    aclboot_master_old
    aclboot_agent
    aclboot_anon_old
    aclboot_repl_old
    aclboot_vault_old
    stat
}

stat() {
    consul_version
    check_repl
    version_sniff
}

version_sniff() {
    load_master_token

    for name in "${all_sorted[@]}"; do
        port=${all_nodes[$name]}
        v=$(version_sniff_one $port)
        echo "$name is at acl version $v"
    done
}
# FROM agent/structs/acl.go:
version_sniff_one() {
    local port=$1

    url="http://localhost:${port}/v1/agent/self"
    ver="$(curl -sL "$url" -H "X-Consul-Token: ${MASTER_TOKEN}" | jq -r .Member.Tags.acls)"
    case "${ver}" in
        0)
            echo "disabled(0)"
            ;;
        1)
            echo "enabled(1)"
            ;;
        2)
            echo "legacy(2)"
            ;;
        3|null)
            echo "unknown(3)"
            ;;
        *)
            die "bad acl mode found: $ver"
    esac
}

consul_version() {
    local name
    local port
    local v
    load_master_token

    for name in "${all_sorted[@]}"; do
        port=${all_nodes[$name]}
        v=$(consul_version_one $port)
        echo "$name is at consul version $v"
    done
}

consul_version_one() {
    local port=$1

    url="http://localhost:${port}/v1/agent/self"
    curl -sL "$url" -H "X-Consul-Token: ${MASTER_TOKEN}" | jq -r .Config.Version
}

do_nuke_test_tokens() {
    load_master_token

    tokens="$(curl -sL "http://localhost:8501/v1/acl/list" \
        -H "X-Consul-Token: ${MASTER_TOKEN}" | \
        jq -r '.[] | select(.Name == "test key for stuff") | .ID')"

    for token in ${tokens[@]}; do
        echo "Nuking token: $token"
        curl -sL -XPUT \
            "http://localhost:8501/v1/acl/destroy/${token}" \
            -H "X-Consul-Token: ${MASTER_TOKEN}" > /dev/null
    done
}

do_sanity() {
    local pri_port="${1:-8501}"
    local sec_port="${2:-9501}"
    load_master_token

    echo "------------------------------"
    echo "Create token (OLD way) for use in limiting KV to /stuff"
    curl -sL -XPUT \
        "http://localhost:${pri_port}/v1/acl/create" \
        -H "X-Consul-Token: ${MASTER_TOKEN}" \
        -d '{
            "Name": "test key for stuff",
            "Type": "client",
            "Rules": "key \"stuff\" { policy = \"write\" }"
        }' > tmp/testkv_token.json
            # "Rules": "{\"key\":{\"stuff\":{\"Policy\":\"write\"}}}"
    local token
    token="$(jq -r .ID < tmp/testkv_token.json)"
    echo "Test token is $token"

    set +e
    do_sanity_args $token primary ${pri_port}
    sleep 2 # wait for replication
    do_sanity_args $token secondary ${sec_port}
    set -e

    echo "------------------------------"
    echo "cleaning up $token"
    curl -sL -XPUT \
        "http://localhost:${pri_port}/v1/acl/destroy/${token}" \
        --retry 10 \
        -H "X-Consul-Token: ${MASTER_TOKEN}" > /dev/null
}
do_sanity_args() {
    if [[ "$#" -lt 3 ]]; then
        die "wrong nargs: $@"
    fi
    local token="$1"
    local name="$2"
    local port="$3"

    echo "========= $name using localhost:$port ===================="

    echo "delete stuff/*"
    consul_cmd "$token" $port kv delete -recurse stuff
    echo "put stuff=root"
    consul_cmd "$token" $port kv put stuff root
    echo "put stuff/child=kiddo"
    consul_cmd "$token" $port kv put stuff/child kiddo

    echo "get stuff/... (should be 2)"
    lines=$(consul_cmd "$token" $port kv get -recurse stuff | wc -l)
    if [[ "$lines" -ne 2 ]]; then
        die "found wrong number of children: expect=2 got=$lines"
    fi

    echo "delete stuff/*"
    consul_cmd "$token" $port kv delete -recurse stuff
}

do_pokev8() {
    load_master_token

    # the endpoints here are all consul-primary-srv1 (:8501)

    echo "================================"
    echo "list members; should see all..."
    if CONSUL_HTTP_ADDR=http://localhost:8501 consul members; then
        :
    else
        echo "...failed completely"
    fi
    # filter acl when querying the catalog
    #     agent/acl.go:	if !a.config.ACLEnforceVersion8 {
    #     agent/consul/acl.go:	filt := newACLFilter(acl, s.logger, s.config.ACLEnforceVersion8)

    echo "================================"
    echo "register catalog node with service should fail..."
    out="$(curl -sL -XPUT 'http://localhost:8501/v1/catalog/register' \
        -d'{
"Node" : "fake-node",
"Address" : "9.9.9.9",
"Service" : {
    "Service" : "fake-service",
    "Address" : "9.9.9.9",
    "Port" : 9999
} }')"
    echo "...worked? $out"
    # node catalog register
    #     agent/consul/catalog_endpoint.go:	if rule != nil && c.srv.config.ACLEnforceVersion8 {

    echo "================================"
    echo "register catalog node with NO services should work..."
    out="$(curl -sL -XPUT 'http://localhost:8501/v1/catalog/register' \
        -d'{
"Node" : "fake-node",
"Address" : "9.9.9.9"
}')"
    echo "...worked? $out"
    # node catalog register
    #     agent/consul/catalog_endpoint.go:	if rule != nil && c.srv.config.ACLEnforceVersion8 {

    echo "================================"
    echo "deregister catalog node with service should work..."

    out="$(curl -sL -XPUT 'http://localhost:8501/v1/catalog/deregister' \
        -d'{
"Node" : "fake-node",
"Address" : "9.9.9.9",
"ServiceID" : "fake-service"
}')"
    echo "...worked? $out"
    # node catalog deregister
    #     agent/consul/catalog_endpoint.go:	if rule != nil && c.srv.config.ACLEnforceVersion8 {

    echo "================================"
    echo "deregister catalog node with NO services should work..."

    out="$(curl -sL -XPUT 'http://localhost:8501/v1/catalog/deregister' \
        -d'{
"Node" : "fake-node",
"Address" : "9.9.9.9"
}')"
    echo "...worked? $out"
    # node catalog deregister
    #     agent/consul/catalog_endpoint.go:	if rule != nil && c.srv.config.ACLEnforceVersion8 {


    echo "================================"
    echo "creating a session should succeed..."
    set +e
    id="$(curl -sL -XPUT http://localhost:8501/v1/session/create \
        -d '{ "Behavior":"delete", "TTL":"1m" }' | jq -r .ID)"
    set -e
    echo "...ID is ${id:-FAILED}"
    # session create
    #     agent/consul/session_endpoint.go:	if rule != nil && s.srv.config.ACLEnforceVersion8 {

    if [[ -z "${id}" ]]; then
        # ok so it legit didn't work, so use a master token to make this
        # instead so we can test RENEW and DELETE
        id="$(curl -sL -XPUT http://localhost:8501/v1/session/create \
            -H "X-Consul-Token: ${MASTER_TOKEN}" \
            -d '{ "Behavior":"delete", "TTL":"1m" }' | jq -r .ID)"
        echo "...ID (created with master token) is ${id}"
        if [[ -z "$id" ]]; then
            die "session creation failed with master token wtf"
        fi
    fi

    echo "================================"
    echo "renewing a session should succeed..."
    set +e
    ttl="$(curl -sL -XPUT http://localhost:8501/v1/session/renew/$id \
        -d '{ "Behavior":"delete", "TTL":"1m" }' | jq -r .[].TTL)"
    set -e
    echo "...renewed with TTL response of ${ttl}"
    # session renew
    #     agent/consul/session_endpoint.go:	if rule != nil && s.srv.config.ACLEnforceVersion8 {

    echo "================================"
    echo "create anonymous prepared query..."
    set +e
    pqid="$(curl -sL -XPOST http:/localhost:8501/v1/query \
        -d '{ "Service": { "Service": "consul" } }' | jq -r .ID)"
    set -e
    echo "...PQID is ${pqid:-FAILED}"
    # create prepared query
    #     agent/consul/prepared_query_endpoint.go:		if err := parseQuery(args.Query, p.srv.config.ACLEnforceVersion8); err != nil {

    if [[ -z "${pqid}" ]]; then
        # ok so it legit didn't work, so use a master token to make this
        # instead so we can test DELETE
        #
        # need to tie to a session as per docs if we definitely want it to
        # exist for further tests below
        pqid="$(curl -sL -XPOST http:/localhost:8501/v1/query \
            -H "X-Consul-Token: ${MASTER_TOKEN}" \
            -d "{
\"Session\": \"${id}\",
\"Service\": {
    \"Service\" : \"consul\"
}
}" | jq -r .ID)"
        echo "...PQID (created with master token) is ${pqid}"
        if [[ -z "$pqid" ]]; then
            die "prepared queyr creation failed with master token wtf"
        fi
    fi

    echo "================================"
    echo "update anonymous prepared query..."
    out="$(curl -sL -XPUT http:/localhost:8501/v1/query/$pqid \
        -d '{ "Service": { "Service": "consul2" } }')"
    echo "...did it work? ${out:-WORKED}"
    # update prepared query
    #     agent/consul/prepared_query_endpoint.go:		if err := parseQuery(args.Query, p.srv.config.ACLEnforceVersion8); err != nil {

    echo "================================"
    echo "destroying a session should succeed..."
    set +e
    ok="$(curl -sL -XPUT http://localhost:8501/v1/session/destroy/$id \
        -d '{ "Behavior":"delete", "TTL":"1m" }')"
    set -e
    echo "...did it work? $ok"
    # session destroy
    #     agent/consul/session_endpoint.go:	if rule != nil && s.srv.config.ACLEnforceVersion8 {

    echo "================================"
    echo "update coordinates..."
    out="$(curl -sL -XPUT http:/localhost:8501/v1/coordinate/update \
        -d '{
"Node": "agent-one",
"Segment": "",
"Coord": {
    "Adjustment": 0,
    "Error": 1.5,
    "Height": 0,
    "Vec": [0, 0, 0, 0, 0, 0, 0, 0]
}
}')"
    echo "...did it work? ${out:-WORKED}"
    # coordinate update
    #     agent/consul/coordinate_endpoint.go:	if rule != nil && c.srv.config.ACLEnforceVersion8 {

    echo "================================"
    echo "read node coordinates..."
    set +e
    out="$(curl -sL http://localhost:8501/v1/coordinate/node/consul-primary-srv1 | \
        jq -r '.[].Node' 2>/dev/null)"
    set -e
    echo "...worked if this says consul-primary-srv1: [$out]"
    # coordinate lookup for node
    #     agent/consul/coordinate_endpoint.go:	if rule != nil && c.srv.config.ACLEnforceVersion8 {
}

consul_cmd() {
    if [[ "$#" -lt 3 ]]; then
        die "wrong nargs: $@"
    fi
    local token="$1"
    local port="$2"
    shift 2
    CONSUL_HTTP_ADDR="http://localhost:${port}" \
        CONSUL_HTTP_TOKEN="${token}" \
        consul "$@"
}

load_upgraded

USE_SECRETS=""
if [[ -f "tmp/.ids.upgraded" ]]; then
    USE_SECRETS=1
fi
USE_NEW_AGENTAPI=""
if [[ -f "tmp/.agentapi.upgraded" ]]; then
    USE_NEW_AGENTAPI=1
fi
ACL_DO_NOT_ENFORCE_VERSION_8=""
if [[ -f "tmp/.disable.acl.v8" ]]; then
    ACL_DO_NOT_ENFORCE_VERSION_8=1
fi

show_usage() {
    cat <<EOF
usage: run.sh <COMMAND>

STANDARD

refresh  - (default) rebuilds configs and containers
destroy  - nukes everything
reconfig - only does the config generation part of 'refresh'
status   - show some container info (alias: stat, st)
restart  - restart all containers
help     - show this

UPGRADES

upgrade-<CONTAINER> - upgrade just the container named <CONTAINER>
upgrade-secondary   - upgrade all secondary DC members to 1.4.0
upgrade-primary     - upgrade all primary DC members to 1.4.0
upgrade-primary-one - upgrade just consul-primary-srv1 to 1.4.0
upgrade-primary-ui  - upgrade just consul-primary-ui to 1.4.0
flag-upgraded       - drop sufficient marker files such that a call to
                      'refresh' will initialize to 1.4.0 (skipping 1.3.0)
flag-agentapi2      - switch to using the ACL v2 Agent API
use-secrets         - will switch to using SecretID if found

TESTING

stop-primary      - stop all server members in the primary datacenter
start-primary     - start all server members in the primary datacenter
restart-secondary - restart all server members in secondary datacenter
testtoken         - mint a simple token for use against KV
sanity            - mint a simple token for use against KV; use it in both
                    DCs; then destroy it
clientsanity      - like 'sanity' but it executes against client nodes
flag-v8-enabled   - mark that acl_enforce_version_8 should be set to true
flag-v8-disabled  - mark that acl_enforce_version_8 should be set to false
pokev8            - poke api endpoints without an ACL token where
                    acl_enforce_version_8=false should NOT mask behaviors
nuke-test-tokens  - cleanup any stray test-generated tokens from the above
EOF
}

readonly mode="${1:-refresh}"
case "${mode}" in
    help)
        show_usage
        ;;
    destroy)
        do_destroy
        ;;
    refresh)
        do_refresh
        ;;
    reconfig)
        genconfig
        ;;
    flag-upgraded)
        for host in "${all_sorted[@]}"; do
            UPGRADED_HOSTS[$host]=1
        done
        write_upgraded
        ;;
    flag-v8-enabled)
        rm -f tmp/.disable.acl.v8
        ACL_DO_NOT_ENFORCE_VERSION_8=""
        genconfig
        restart
        ;;
    flag-v8-disabled)
        touch tmp/.disable.acl.v8
        ACL_DO_NOT_ENFORCE_VERSION_8=1
        genconfig
        restart
        ;;
    upgrade-secondary)
        for host in "${sec_sorted[@]}"; do
            UPGRADED_HOSTS[$host]=1
        done
        write_upgraded
        build
        ;;
    upgrade-primary)
        for host in "${pri_sorted[@]}"; do
            UPGRADED_HOSTS[$host]=1
        done
        write_upgraded
        build
        ;;
    upgrade-primary-ui)
        UPGRADED_HOSTS[consul-primary-ui]=1
        write_upgraded
        build
        ;;
    upgrade-primary-one)
        UPGRADED_HOSTS[consul-primary-srv1]=1
        write_upgraded
        build
        ;;
    upgrade-*)
        host="${mode/#upgrade-/}"
        if [[ -z "$host" ]]; then
            die "expected format upgrade-<hostname>"
        fi

        valid=""
        for testhost in "${all_sorted[@]}"; do
            if [[ "$testhost" = "$host" ]]; then
                valid=1
                break
            fi
        done
        if [[ -z "$valid" ]]; then
            die "invalid host: $host"
        fi

        UPGRADED_HOSTS[$host]=1
        write_upgraded
        build
        ;;
    status|stat|st)
        stat
        ;;
    sanity)
        do_sanity 8501 9501
        ;;
    clientsanity)
        # same thing but against clients
        do_sanity 8504 9504
        ;;
    pokev8)
        do_pokev8
        ;;
    nuke-test-tokens)
        do_nuke_test_tokens
        ;;
    restart)
        restart
        ;;
    stop-primary)
        docker stop consul-primary-srv{1,2,3}
        ;;
    start-primary)
        docker start consul-primary-srv{1,2,3}
        ;;
    restart-secondary)
        docker restart consul-secondary-srv{1,2,3}
        ;;
    use-secrets)
        touch tmp/.ids.upgraded
        USE_SECRETS=1
        build
        ;;
    flag-agentapi2)
        touch tmp/.agentapi.upgraded
        USE_NEW_AGENTAPI=1
        ;;
    testtoken)
        echo "Creating key for use in testing KV under stuff/..."
        curl -sL -XPUT http://localhost:8501/v1/acl/create \
            -H "X-Consul-Token: $(< tmp/master_token.json jq -r .ID)" \
            -d '{
                "Name": "special test token",
                "Type": "client",
                "Rules": "{\"key\":{\"altstuff\":{\"Policy\":\"write\"}}}"
            }' > tmp/test_token.json
        sleep 2
        token="$(load_idfile test token)"
        CONSUL_HTTP_TOKEN=${token} CONSUL_HTTP_ADDR=http://localhost:9501 consul kv put altstuff randombits
        echo "Your token: $token"
        echo
        echo "Now check in another terminal with:"
        echo
        echo "CONSUL_HTTP_TOKEN=${token} CONSUL_HTTP_ADDR=http://localhost:9501 watch -n 1 -d 'date; consul kv get altstuff'"
        echo
        ;;
    *)
        die "unknown mode: ${mode}"
        ;;
esac
