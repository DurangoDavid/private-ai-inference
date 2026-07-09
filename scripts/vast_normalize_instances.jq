# Input (slurped): array of v1 instance objects from /api/v1/instances/.
# Output: {"success":true,"instances":[ <normalized>, ... ]}
#
# Normalization keeps the v1 fields we use and adds:
#   ssh_host_port - the host port for SSH: prefer the v1 top-level `ssh_port`,
#                   fall back to the legacy `ports["22"]` map (array -> .[0],
#                   object -> HostPort, else the raw value).
#   reliability   - alias of v1's `reliability2` (v0 named it `reliability`).
def sshport:
  if (.ssh_port // null) != null then .ssh_port
  else
    ((.ports // {}) | (.["22"] // .["22/tcp"])) |
    if . == null then null
    elif (type == "array") then .[0]
    elif (type == "object") then (.HostPort // (.[0].HostPort // null))
    else . end
  end;
{success:true, instances: map(. + {
  ssh_host_port: sshport,
  reliability: .reliability2
})}