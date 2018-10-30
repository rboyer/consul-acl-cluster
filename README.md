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
```
