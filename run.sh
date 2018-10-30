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
REPL_TOKEN=""

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
   "acl_datacenter" : "primary",
   "acl_default_policy" : "deny",
   "acl_down_policy": "async-cache"
}
EOF
    cat > "${new_dir}/acl.json" <<EOF
{
  "primary_datacenter": "primary",
  "acl": {
    "enabled": true,
    "enable_token_replication": true,
    "default_policy": "deny",
    "down_policy": "async-cache"
  }
}
EOF

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

build() {
    genconfig

    local pri
    local sec
    if [[ -n "$PRIMARY_NEW" ]]; then
        pri=false
    else
        pri=true
    fi
    if [[ -n "$SECONDARY_NEW" ]]; then
        sec=false
    else
        sec=true
    fi

    pri_svr1_leg=$pri
    if [[ -n "${UPGRADE_ONLY:-}" ]]; then
        if [[ "$UPGRADE_ONLY" != "consul-primary-svr1" ]]; then
            die "unexpected value"
        fi
        pri_svr1_leg=false
    fi

    terraform apply -auto-approve \
        -var primary_srv1_legacy=$pri_svr1_leg \
        -var primary_srv2_legacy=$pri \
        -var primary_srv3_legacy=$pri \
        -var primary_ui_legacy=$pri \
        -var enable_secondary=true \
        -var secondary_srv1_legacy=$sec \
        -var secondary_srv2_legacy=$sec \
        -var secondary_srv3_legacy=$sec \
        -var secondary_ui_legacy=$sec \
        -var secondary_client1_legacy=$sec \
        -var secondary_client2_legacy=$sec

    wait_all
}

check_token() {
    local name="$1"
    local fn="tmp/${name}_token.json"
    if [[ ! -f "$fn" ]]; then
        die "missing ${name} token file: ${fn}"
    fi
    if [[ ! -s "$fn" ]]; then
        rm -f "${fn}"
        die "empty ${name} token file (now erased): ${fn}"
    fi
	if ! < "$fn" jq .ID >/dev/null 2>&1 ; then
        die "bad ${name} token file: ${fn}"
	fi
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
    if [[ "${1:-}" != "check" ]]; then
        check_token master
    fi

    local token
	token="$(jq -r .ID < tmp/master_token.json)"
    if [[ "${MASTER_TOKEN}" != "${token}" ]]; then
        MASTER_TOKEN="${token}"
        echo "Master Token is ${MASTER_TOKEN}"
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
load_agent_token() {
    if [[ "${1:-}" != "check" ]]; then
        check_token agent
    fi

    local token
	token="$(jq -r .ID < tmp/agent_token.json)"
    if [[ "${AGENT_TOKEN}" != "${token}" ]]; then
        AGENT_TOKEN="${token}"
        echo "Agent Token is ${AGENT_TOKEN}"
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
    if [[ "${1:-}" != "check" ]]; then
        check_token repl
    fi

    local token
	token="$(jq -r .ID < tmp/repl_token.json)"
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

do_refresh() {
    # set -x
    # genconfig
    # restart
    build
    # exit 0

    aclboot_master_old
    aclboot_agent_old
    aclboot_anon_old
    aclboot_repl_old
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
    load_master_token

    echo "------------------------------"
    echo "Create token (OLD way) for use in limiting KV to /stuff"
    curl -sL -XPUT \
        "http://localhost:8501/v1/acl/create" \
        -H "X-Consul-Token: ${MASTER_TOKEN}" \
        -d '{
            "Name": "test key for stuff",
            "Type": "client",
            "Rules": "{\"key\":{\"stuff\":{\"Policy\":\"write\"}}}"
        }' > tmp/testkv_token.json
	local token
    token="$(jq -r .ID < tmp/testkv_token.json)"
    echo "Test token is $token"

    do_sanity_args $token primary 8501
    sleep 2 # wait for replication
    do_sanity_args $token secondary 9501

    echo "------------------------------"
    echo "cleaning up $token"
    curl -sL -XPUT \
        "http://localhost:8501/v1/acl/destroy/${token}" \
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

PRIMARY_NEW=""
if [[ -f "tmp/.primary.upgraded" ]]; then
    PRIMARY_NEW=1
fi

SECONDARY_NEW=""
if [[ -f "tmp/.secondary.upgraded" ]]; then
    SECONDARY_NEW=1
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

upgrade-secondary   - upgrade all secondary DC members to 1.4.0
upgrade-primary     - upgrade all primary DC members to 1.4.0
upgrade-primary-one - upgrade just consul-primary-srv1 to 1.4.0
flag-upgraded       - drop sufficient marker files such that a call to
                      'refresh' will initialize to 1.4.0 (skipping 1.3.0)

TESTING

stop-primary     - stop all members in the primary datacenter
start-primary    - start all members in the primary datacenter
testtoken        - mint a simple token for use against KV
sanity           - mint a simple token for use against KV; use it in both
                   DCs; then destroy it
nuke-test-tokens - cleanup any stray test-generated tokens from the above
EOF
}

readonly mode="${1:-refresh}"
case "${mode}" in
    help)
        show_usage
        ;;
    destroy)
        echo "Destroying everything..."
        do_destroy
        ;;
    refresh)
        do_refresh
        ;;
    reconfig)
        genconfig
        ;;
    flag-upgraded)
        touch tmp/.primary.upgraded
        touch tmp/.secondary.upgraded
        ;;
    upgrade-secondary)
        touch tmp/.secondary.upgraded
        SECONDARY_NEW=1
        build
        ;;
    upgrade-primary-one)
        UPGRADE_ONLY=consul-primary-svr1
        build
        ;;
    upgrade-primary)
        touch tmp/.primary.upgraded
        PRIMARY_NEW=1
        build
        ;;
    status|stat|st)
        stat
        ;;
    sanity)
        do_sanity
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
    testtoken)
        echo "Creating key for use in testing KV under stuff/..."
        curl -sL -XPUT http://localhost:8501/v1/acl/create \
            -H "X-Consul-Token: $(< tmp/master_token.json jq -r .ID)" \
            -d '{
                "Name": "test key for stuff",
                "Type": "client",
                "Rules": "{\"key\":{\"stuff\":{\"Policy\":\"write\"}}}"
            }'
        echo "Now check in another terminal with:"
        echo "  CONSUL_HTTP_TOKEN=YOUR_TOKEN"
        echo "  CONSUL_HTTP_ADDR=http://localhost:9501"
        echo "watch -n 1 -d 'date; consul kv get stuff'"
        echo
        ;;
    *)
        die "unknown mode: ${mode}"
        ;;
esac
