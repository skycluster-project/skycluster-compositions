import base64
import json
import crypto
import yaml
import provider_kubernetes.v1alpha2 as k8sv1alpha2
import provider_helm.v1beta1 as helmv1beta1
import helper.v1alpha1.main as helper

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
# _dxr = option("params").dxr # desired composite resource
# dcds = option("params").dcds # desired composed resources

# assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
# assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"
_secrets = _extraRes["Secrets"] or Undefined
assert _secrets is not Undefined, "Secrets resource must be provided in the extra resources"

# For Submariner
_brokerSecrets = [sc for sc in _secrets if "submariner-k8s-broker-client" in sc.metadata.name] or []
assert len(_brokerSecrets) == 1, "Exactly one broker secret must be provided in the extra resources"
_brokerSecret = _brokerSecrets[0]

_brokerCA = _brokerSecret.data?["ca.crt"] or Undefined
assert _brokerCA is not Undefined, "Broker CA certificate must be provided in the broker secret"
_brokerToken = _brokerSecret.data?["token"] or Undefined
assert _brokerToken is not Undefined, "Broker token must be provided in the broker secret"

# Generate a random PSK (Pre-Shared Key) for the broker 64 characters long
_ocdsPskDecoded = ocds?["submarinerSecretObj"]?.Resource?.status?.atProvider?.manifest?.data?["values.yaml"]
_ocdsPsk = json.decode(base64.decode(_ocdsPskDecoded))?.ipsec?.psk if _ocdsPskDecoded else Undefined
_psk = _ocdsPsk if _ocdsPsk else crypto.uuid().replace("-", "") + crypto.uuid().replace("-", "")[:32]

# _brokerPrivateIp = _brokerEndpoint.endpoints?[0]?.addresses?[0] or Undefined
# assert _brokerPrivateIp is not Undefined, "Broker private IP must be provided in the broker endpoint"


_xsetup = _extraRes["XSetups"]?[0] or Undefined
assert _xsetup is not Undefined, "XSetup resource must be provided in the extra resources"

_apiServer = _xsetup.status?.apiServer or Undefined
assert _apiServer is not Undefined, "Broker public IP and port must be provided"
_ns = "skycluster-system"

_k8sProvCfgName = _xsetup.status?.providerConfig?.kubernetes?.name or Undefined
_helmProvCfgName = _xsetup.status?.providerConfig?.helm?.name or Undefined

_items = []

# We need to get data from cluster to determind the cluster and service CIDRs
_items += [
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("clusterServiceCidrObj")
      }
    }
    spec = {
      forProvider.manifest = {
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata = { 
          name = "kubeadm-config",
          namespace = "kube-system",
        }
      }
      managementPolicies = ["Observe"]
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }
] if _k8sProvCfgName or ocds?["clusterServiceCidrObj"] else []

_clusterCidrYaml = ocds?["clusterServiceCidrObj"]?.Resource?.status?.atProvider?.manifest?.data?["ClusterConfiguration"] or Undefined
_clusterCidr = yaml.decode(_clusterCidrYaml)?["networking"]?["podSubnet"] if _clusterCidrYaml else Undefined
_serviceCidr = yaml.decode(_clusterCidrYaml)?["networking"]?["serviceSubnet"] if _clusterCidrYaml else Undefined

# Create a secret for Submariner connection
_items += [
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("submarinerSecretObj"),
      }
    }
    spec = {
      forProvider.manifest = {
        apiVersion = "v1"
        kind = "Secret"
        metadata = { 
          name = "submariner-connection-secret",
          namespace = _ns,
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/config-type": "connection-secret"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        type: "Opaque"
        stringData = {
          "values.yaml" = json.encode({
            "ipsec": {
              "psk": _psk
            },
            "broker": {
              "server": _apiServer,
              "namespace": _ns,
              "ca" : _brokerCA, 
              "token": base64.decode(_brokerToken),
            }
          })
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }
] if (_clusterCidr and _serviceCidr) or ocds?["submarinerSecretObj"] else []

_submarinerSecretName = ocds?["submarinerSecretObj"]?.Resource?.status?.atProvider?.manifest?.metadata?.name or Undefined

# submarinerClientCluster
_items += [
  helmv1beta1.Release{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("submarinerClientCluster")
      }
    }
    spec = {
      forProvider = {
        chart = {
          name = "submariner-operator"
          repository = "https://submariner-io.github.io/submariner-charts/charts"
          version = "0.20.1"
        }
        namespace = "submariner-operator"
        skipCreateNamespace = True
        valuesFrom = [{
            secretKeyRef = {
              key = "values.yaml"
              name = _submarinerSecretName if _submarinerSecretName else "submariner-connection-secret"
              namespace = _ns if _ns else "skycluster-system"
            }
        }]
        values = {
          submariner = {
            serviceDiscovery = "false",
            cableDriver = "wireguard",
            clusterId = "broker-skycluster",
            clusterCidr = _clusterCidr,
            serviceCidr = _serviceCidr,
            natEnabled = "true"
          }
        }
      }
      providerConfigRef = {
        name = _helmProvCfgName
      }
    }
  }
] if helper._ready(ocds?["submarinerSecretObj"]) or ocds?["submarinerClientCluster"] else []


_apiServerForHeadscale = _apiServer.split(":")[0]
assert _apiServerForHeadscale, "API server address must be provided"

# Pod Generating Headscale Certificate
_items += [
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("headscaleCertGenPod")
      }
    }
    spec =  {
      forProvider.manifest = {
        apiVersion = "v1"
        kind = "Pod"
        metadata = { 
          name = "headscale-cert-gen",
          namespace = _ns if _ns else "skycluster-system",
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/pod-type": "headscale-cert-gen"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        spec = {
          restartPolicy = "Never"
          containers = [{
            name = "headscale-cert-gen"
            image = "etesami/ca-signer:latest"
            imagePullPolicy = "Always"
            env = [
              {
                name = "CA_SECRET_NAME"
                value = "skycluster-self-ca"
              },
              {
                name = "OUTPUT_SECRET_NAME"
                value = "headscale-cert"
              },
              {
                name = "NAMESPACE"
                value = _ns if _ns else "skycluster-system"
              },
              {
                name = "CERT_COMMON_NAME"
                value = "skycluster.local"
              },
              {
                name = "CERT_SANS"
                value = "DNS:skycluster.local,IP:{}".format(_apiServerForHeadscale)
              }
            ]
          }]
          serviceAccountName = "skycluster-sva"
          restartPolicy = "Never"
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }
] if (_k8sProvCfgName and _apiServerForHeadscale) or ocds?["headscaleCertGenPod"] else []


# Headscale-server Deployment
_items += [
  # Init and main headscale-server containers
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("headscaleServerDeployment")
      }
    }
    spec =  {
      forProvider.manifest = {
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = { 
          name = "headscale-server",
          namespace = _ns if _ns else "skycluster-system",
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/deploy-type": "headscale-server"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        spec = {
          selector.matchLabels = {"app": "headscale-server"}
          template = {
            metadata.labels = {"app": "headscale-server"}
            spec = {
              volumes = [
                {
                  name = "config-volume"
                  persistentVolumeClaim = {
                    claimName = "headscale-config-pvc"
                  }
                },
                {
                  name = "headscale-storage",
                  persistentVolumeClaim = {
                    claimName = "headscale-pvc"
                  }
                }
              ]
              initContainers = [{
                name = "headscale-init"
                image = "etesami/headscale-init:latest"
                env = [
                  {
                    name = "SECRET_NAMESPACE"
                    value = _ns if _ns else "skycluster-system"
                  },
                  {
                    name = "SECRET_NAME"
                    value = "headscale-cert"
                  },
                  {
                    name = "HEADSCALE_SERVER_URL"
                    value = "https://{}:8080".format(_apiServerForHeadscale)
                  }
                ]
                volumeMounts = [{
                  name = "config-volume"
                  mountPath = "/config"
                }]
                workingDir = "/app"
              }, {
                name = "headscale-config-viewer"
                image = "alpine:3.22.1"
                command = ["/bin/sh", "-c"]
                args = ["ls /etc/headscale && cat /etc/headscale/config.yml"]
                volumeMounts = [{
                  name = "config-volume"
                  mountPath = "/etc/headscale"
                }]
              },{
                name = "headscale-init-config",
                image = "etesami/headscale-init-config:latest",
                volumeMounts = [{
                  name = "config-volume",
                  mountPath = "/etc/headscale"
                }, {
                  name = "headscale-storage",
                  mountPath = "/var/lib/headscale"
                }]
              }]
              containers = [{
                name = "headscale-server"
                image = "etesami/headscale-server:c3354cb"
                volumeMounts = [{
                  name = "config-volume"
                  mountPath = "/etc/headscale"
                }, {
                  name = "headscale-storage"
                  mountPath = "/var/lib/headscale"
                }]
                args = [
                  "serve",
                  "--config",
                  "/etc/headscale/config.yml"
                ]
                ports = [{
                  containerPort = 8080
                  protocol = "TCP"
                }]
              }]
              serviceAccountName = "skycluster-sva"
            }
          }
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }
  
  # Service for headscale-server
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("headscaleServerService")
      }
    }
    spec = {
      forProvider.manifest = {
        apiVersion = "v1"
        kind = "Service"
        metadata = { 
          name = "headscale-server",
          namespace = _ns if _ns else "skycluster-system",
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/service-type": "headscale-server"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        spec = {
          type = "NodePort"
          ports = [{
            port = 8080
            targetPort = 8080
            nodePort = 30080
          }]
          selector = {"app": "headscale-server"}
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }

] if helper._ready(ocds?["headscaleCertGenPod"]) or ocds?["headscaleServerDeployment"] else []


dxr = [{
  **option("params").dxr 
  status.connectionSecretName = _submarinerSecretName if _submarinerSecretName else Undefined
  status.namespace = _ns if _ns else Undefined
}] 

items = _items + dxr