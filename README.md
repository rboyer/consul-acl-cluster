scripts for kicking the tires during a consul acl v1 -> v2 upgrade
-----------------------------------------------------

The main entrypoint is ./run.sh (or 'make' if that's your jam).

```
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
```
