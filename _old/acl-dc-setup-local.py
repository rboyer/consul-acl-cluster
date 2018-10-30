#!/usr/bin/env python3
import requests
import pprint
import termcolor
import os
import sys
import json
import time
from urllib.parse import urljoin

nodes = {
   "primary-srv1" : {
      'api' : 'http://localhost:8501',
      'name' : 'consul-primary-srv1',
      'replication': True
   },
   "primary-srv2" : {
      'api' : 'http://localhost:8502',
      'name' : 'consul-primary-srv2',
      'replication': True
   },
   "primary-srv3" : {
      'api' : 'http://localhost:8503',
      'name' : 'consul-primary-srv3',
      'replication': True
   },
   'primary-ui' : {
      'api' : 'http://localhost:8504',
      'name' : 'consul-primary-ui',
      'replication': False
   },
   "secondary-srv1" : {
      'api' : 'http://localhost:9501',
      'name' : 'consul-secondary-srv1',
      'replication': True
   },
   "secondary-srv2" : {
      'api' : 'http://localhost:9502',
      'name' : 'consul-secondary-srv2',
      'replication': True
   },
   "secondary-srv3" : {
      'api' : 'http://localhost:9503',
      'name' : 'consul-secondary-srv3',
      'replication': True
   },
   "secondary-client1" : {
      'api' : 'http://localhost:9504',
      'name' : 'consul-secondary-client1',
      'replication': False,
   },
   "secondary-client2" : {
      'api' : 'http://localhost:9505',
      'name' : 'consul-secondary-client2',
      'replication': False,
   },
   "secondary-ui" : {
      'api' : 'http://localhost:9506',
      'name' : 'consul-secondary-ui',
      'replication': False,
   },
}

apiaddr = nodes['primary-srv1']['api']

def fatal_err(title, message):
   print(termcolor.colored('===> {0} <==='.format(title), 'red'))
   print(message)
   print(termcolor.colored('=' * (10 + len(title)), 'red'))
   sys.exit(1)

def print_status(message):
   print(termcolor.colored(message, 'blue'))

def pretty_json(obj):
   return json.dumps(obj, indent=4, sort_keys=True)

def print_resp(name, message):
   print(termcolor.colored('===> {0} <==='.format(name), 'green'))
   print(message)
   print(termcolor.colored('=' * (10 + len(name)), 'green'))

def waitForPeers(node, expected):
   nodeapi = nodes[node]['api']
   done = False
   while not done:
      try:
         resp = requests.get(urljoin(nodeapi, 'v1/status/peers'))
         if resp.status_code != 200:
            time.sleep(0.25)
         else:
            peers = resp.json()
            if len(peers) == expected:
               done = True
            else:
               time.sleep(0.1)
      except:
         time.sleep(1)

def waitForLeader(node):
   nodeapi = nodes[node]['api']
   done = False
   while not done:
      try:
         resp = requests.get(urljoin(nodeapi, 'v1/status/leader'))
         if resp.status_code != 200:
            time.sleep(0.25)
         else:
            leader = resp.json()
            if leader != "":
               done = True
            else:
               time.sleep(0.1)
      except:
         time.sleep(1)


print_status('===> Waiting for the primary datacenter leader election')
waitForPeers('primary-srv1', 3)
waitForPeers('primary-srv2', 3)
waitForPeers('primary-srv3', 3)
waitForLeader('primary-srv1')
waitForLeader('primary-srv2')
waitForLeader('primary-srv3')


print_status('===> Bootstrapping ACLs in the primary datacenter')

# Bootstrap ACLs
done = False
resp = None
while not done:
   try:
      resp = requests.put(urljoin(apiaddr, 'v1/acl/bootstrap'))
      if resp.status_code != 200:
         if resp.text == "The ACL system is currently in legacy mode.":
            time.sleep(0.1)
         else:
            done = True
      else:
         done = True
   except Exception as e:
      print("{0}".format(e))
      time.sleep(0.25)

if resp is None:
   fatal_err("Bootstrap Error", 'unknown error')

if resp.status_code != 200:
   fatal_err('Bootstrap Error', resp.text)

bootstrap_token = resp.json()
print_resp('Bootstrap Token', pretty_json(bootstrap_token))

agent_policy = {
   "Name": "agent-default",
   "Description": "Can do read operations on any service and register the node",
   "Rules": '''
node_prefix "consul-" {
   policy = "write"
}
service_prefix "" {
   policy = "read"
}'''
}

replication_policy = {
   "Name": "policy-replication",
   "Description": "This policy encompasses the permissions required to do policy-only replication",
   "Rules": 'acl = "read"'
}

token_replication_policy = {
   "Name": "token-replication",
   "Description": "This policy encompasses the permissions required to do policy-only replication",
   "Rules": 'acl = "write"'
}


acl_header = {'X-Consul-Token': bootstrap_token['SecretID']}

print_status('====> Creating the Agent policy')
resp = requests.put(urljoin(apiaddr, 'v1/acl/policy'), json=agent_policy, headers=acl_header)
if resp.status_code != 200:
   fatal_err('Policy Create (Agent) Error', resp.text)

agent_policy = resp.json()
print_resp('Policy Create (Agent)', pretty_json(agent_policy))

print_status('====> Creating the Replication policy')
resp = requests.put(urljoin(apiaddr, 'v1/acl/policy'), json=replication_policy, headers=acl_header)
if resp.status_code != 200:
   fatal_err('Policy Create (Replication) Error', resp.text)

replication_policy = resp.json()
print_resp('Policy Create (Replication)', pretty_json(replication_policy))

resp = requests.put(urljoin(apiaddr, 'v1/acl/policy'), json=token_replication_policy, headers=acl_header)
if resp.status_code != 200:
   fatal_err('Policy Create (Token Replication) Error', resp.text)

token_replication_policy = resp.json()
print_resp('Policy Create (Token Replication)', pretty_json(token_replication_policy))

def pushAgentToken(tokens, node):
   print_status('====> Setting Default ACL Token for {0}'.format(node))
   node_name = nodes[node]['name']
   node_api = nodes[node]['api']
   token = tokens[node]['agent']

   resp = requests.put(urljoin(node_api, 'v1/agent/token/acl_agent_token'), json=dict(Token=token), headers=acl_header)
   if resp.status_code != 200:
      fatal_err('Update ACL Agent Token ({0}) Error'.format(node_name), resp.text)
   else:
      print(termcolor.colored('Updated ACL Agent Token ({0}) Success'.format(node_name), 'green'))

def pushReplicationToken(tokens, node):
   print_status('====> Setting Replication Token for {0}'.format(node))
   node_name = nodes[node]['name']
   node_api = nodes[node]['api']
   token = tokens[node]['replication']

   resp = requests.put(urljoin(node_api, 'v1/agent/token/acl_replication_token'), json=dict(Token=token), headers=acl_header)
   if resp.status_code != 200:
      fatal_err('Update ACL Replication Token ({0}) Error'.format(node_name), resp.text)
   else:
      print(termcolor.colored('Updated ACL Replication Token ({0}) Success'.format(node_name), 'green'))

def generateAgentTokens(token):
   print_status('====> Generating Agent and Replication Tokens')
   tokens = {}

   for srv in nodes:
      node_name = nodes[srv]['name']
      node_api = nodes[srv]['api']
      token_input = {
         "Description": "{0} agent token".format(node_name),
         "Policies": [
            dict(ID=agent_policy['ID'])
         ]
      }

      resp = requests.put(urljoin(apiaddr, 'v1/acl/token'), json=token_input, headers=acl_header)
      if resp.status_code != 200:
         fatal_err('Token Create (Agent - {0}) Error'.format(node_name), resp.text)

      agent_token = resp.json()
      print_resp('Token Create (Agent - {0})'.format(node_name), pretty_json(agent_token))

      replication_token = {'SecretID': ""}
      if nodes[srv]['replication']:
         token_input = {
            "Description": "{0} replication token".format(node_name),
            "Policies": [
               dict(ID=token_replication_policy['ID'] if token else replication_policy['ID'])
            ]
         }

         resp = requests.put(urljoin(apiaddr, 'v1/acl/token'), json=token_input, headers=acl_header)
         if resp.status_code != 200:
            fatal_err('Token Create (Replication - {0}) Error'.format(node_name), resp.text)

         replication_token = resp.json()
         print_resp('Token Create (Replication - {0})'.format(node_name), pretty_json(replication_token))

      tokens[srv] = dict(agent=agent_token['SecretID'], replication=replication_token['SecretID'])

   return tokens

tokens = generateAgentTokens(True)

pushAgentToken(tokens, 'primary-srv1')
pushAgentToken(tokens, 'primary-srv2')
pushAgentToken(tokens, 'primary-srv3')
# make sure the client knows about the servers
waitForPeers('primary-ui', 3)
waitForLeader('primary-ui')
pushAgentToken(tokens, 'primary-ui')

print_status('====> Waiting for secondary datacenter to elect a leader')
waitForPeers('secondary-srv1', 3)
waitForPeers('secondary-srv2', 3)
waitForPeers('secondary-srv3', 3)
waitForLeader('secondary-srv1')
waitForLeader('secondary-srv2')
waitForLeader('secondary-srv3')
pushAgentToken(tokens, 'secondary-srv1')
pushAgentToken(tokens, 'secondary-srv2')
pushAgentToken(tokens, 'secondary-srv3')
print_status('====> Waiting for secondary datacenter clients to see the leader')
waitForPeers('secondary-client1', 3)
waitForPeers('secondary-client2', 3)
waitForPeers('secondary-ui', 3)
waitForLeader('secondary-client1')
waitForLeader('secondary-client2')
waitForLeader('secondary-ui')
pushAgentToken(tokens, 'secondary-client1')
pushAgentToken(tokens, 'secondary-client2')
pushAgentToken(tokens, 'secondary-ui')
pushReplicationToken(tokens, 'secondary-srv1')
pushReplicationToken(tokens, 'secondary-srv2')
pushReplicationToken(tokens, 'secondary-srv3')

def createLegacyToken(name, tokType, rules):
   token = {
      "Name": name,
      "Type": tokType,
      "Rules": rules
   }

   resp = requests.put(urljoin(apiaddr, 'v1/acl/create'), json=token, headers=acl_header)
   if resp.status_code != 200:
      fatal_err('Legacy Token Creation Error', resp.text)

   tok = resp.json()
   print_resp('Legacy Token Creation Success', pretty_json(tok))

for i in range(3):
   createLegacyToken('legacy-management-{0}'.format(i+1), 'management', '')

for i in range(3):
   createLegacyToken('legacy-client-{0}'.format(i+1), 'client', 'key "" { policy = "write" }')

