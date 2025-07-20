import json
import base64
import crypto
import helper.v1alpha1.main as helper
import provider_helm.v1alpha1.release as helmrelease

oxr = option("params")?.oxr
assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

extrRes = ctx["apiextensions.crossplane.io/extra-resources"]
_search_list: (list,str) -> any = lambda l, k {
  re = map e in l { e.metadata.name }
  ch= any e in re { k in e } 
  [item for item in l if k in item["metadata"]["name"]][0] if ch else None
}

_secret = _search_list(extrRes["Secrets"], "submariner-k8s-broker-client-token")
_broker_ca = _secret["data"]["ca.crt"] if _secret else None
_broker_token = _secret["data"]["token"] if _secret else None

# oxr.spec.broker.ip and oxr.spec.broker.port are expected to be set in the Broker spec
_k8s_ip = oxr.spec.broker.ip
_k8s_port = oxr.spec.broker.port
_broker_url = "https://${_k8s_ip}:${_k8s_port}" if _k8s_ip and _k8s_port else None

# Generate a random PSK (Pre-Shared Key) for the broker 64 characters long
_psk = crypto.uuid().replace("-", "") + crypto.uuid().replace("-", "")[:31]

hr = helmrelease.Release{
  metadata: {
    labels: oxr.metadata?.labels
    annotations: {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("broker"),
    }
  },
  spec: {
    forProvider: {
      chart: {
        name: "submariner-k8s-broker",
        version: "0.20.1",
        repository: "https://submariner-io.github.io/submariner-charts/charts",
      },
      namespace: "submariner-k8s-broker",
    },
    providerConfigRef: {
      name: "provider-helm",
    },
  }
}

_dxrStatus = {
  ca: _broker_ca
  token: _broker_token
  url: _broker_url
  psk: _psk
} if _broker_ca and _broker_token and _broker_url else {}

dxr= {
  **option("params").dxr,
  status.broker = _dxrStatus,
  # status.dummy = "${len(extrRes['Secrets'])}",
  # status.dummy = "______".join([l.metadata.name for l in extrRes["Secrets"]]),
}

items = [hr, dxr]
