# import json
# import base64
# import yaml
# import regex as re
import helper.v1alpha1.main as helper
import net
# import math

_oxr = option("params").oxr # observed composite resource
_ocds = option("params")?.ocds # observed composed resources

_fn_net = lambda cidr, additional_bits, num_bits {
  ip_str = cidr.split("/")[0]
  base_len = int(cidr.split("/")[1])

  # Calculate new prefix length
  len = base_len + additional_bits

  # Convert base IP to integer
  parts = [int(p) for p in ip_str.split(".")]
  base_ip = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]

  # Add subnet offset and mask to network address
  new_ip_num = (base_ip + (num_bits << (32 - len))) & (~((1 << (32 - len)) - 1) & 0xFFFFFFFF)

  # Convert back to dotted string
  a = (new_ip_num >> 24) & 0xFF
  b = (new_ip_num >> 16) & 0xFF
  c = (new_ip_num >> 8) & 0xFF
  d = new_ip_num & 0xFF

  # Final CIDR string
  "{}.{}.{}.{}/{}".format(a, b, c, d, len)
}
#     (
#         (lambda a,b,c,d: (a<<24)|(b<<16)|(c<<8)|d)(*map(int, ipv4.split('.')))
#         + (net_num << (32 - length))
#     )
#     & (~((1 << (32 - length)) - 1) & 0xFFFFFFFF)
# )



# _ctx = option("params")?.ctx
# _extraRes = _ctx["apiextensions.crossplane.io/extra-resources"]
# assert _extraRes is not Undefined, "Extra resources must be provided in the context"

# _provSettings = _extraRes["ProviderSettings"]?[0] 
# assert _provSettings is not Undefined, "Provider settings must be provided in the extra resources"

x = "10.10.0.0/16"
# _vpcCidrDict = net.parse_CIDR(_vpcCidr)
# _vpcCidrIp = _vpcCidrDict["ip"]
# _vpcCidrMask = _vpcCidrDict["mask"]

# remainingCidr = 32 - _vpcCidrMask
# a1 = math.log2(remainingCidr)

# Subnet A: first half (quarters 0 + 1)
subnet_a = net.CIDR_subnet(x, 1, 0)      
subnet_b = net.CIDR_subnet(x, 2, 2)      
subnet_c = net.CIDR_subnet(x, 2, 3)      

subnet_a1 = _fn_net(x, 1, 0)      
subnet_b1 = _fn_net(x, 2, 2)      
subnet_c1 = _fn_net(x, 2, 3)      

# a = net.CIDR_subnets("10.10.0.0/16", [1, 2, 3, 4, 5, 6, 7, 8])
# a1  = net.CIDR_host(_vpcCidr, 1)
# a2  = net.CIDR_host(_vpcCidr, 2)
# a3  = net.CIDR_host(_vpcCidr, 3)
# ax  = net.CIDR_host(_vpcCidr, 256)

# _text = "projects/skycluster-445316/regions/us-east1/subnetworks/gcp-provider-us-east1-lwlzs"
# subnetName = re.replace(_text, r'^.*/', "")


# project = re.replace(s, r"/serviceAccounts/.*$", "")
# -> "my-project"


# # findall returns a list of captured groups if parentheses are used
# matches = re.findall(_text, _pattern)

# project_id = matches[0] if matches else Undefined


# images = yaml.decode(_provSettings?.data?["images.yaml"]) \
#        if _provSettings?.data?["images.yaml"] else Undefined

# _zone = "us-east1-a"
# _itLabel = "2vCPU-4GB"
# _itypesYaml = yaml.decode(_provSettings?.data?["flavors.yaml"]) \
#         if _provSettings?.data?["flavors.yaml"] else Undefined

#     # we expect one member: (flavors (list), zoneName)
# _itypesZone = [fz.flavors for fz in _itypesYaml if fz.zonename == _zone]
# itypes = [{
# ram = fl.ram
# cpu = fl.cpu
# name = fl.name
# nameLabel = fl.namelabel
# generation = fl.generation
# price = fl.price
# } for fl in _itypesZone[0]]

# [d.name for d in _itypes if d.nameLabel == _itLabel]