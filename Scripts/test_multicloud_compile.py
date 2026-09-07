#!/usr/bin/env python3
"""Prove cloud, account, network, region and CPU mismatches fail in Swift."""
import pathlib
import platform
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(['swift', 'build', '--jobs', '1'], cwd=root, check=True)
binary = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
command = ['swiftc', '-typecheck', '-I', str(binary / 'Modules')]
if sys.platform == 'darwin':
    command += ['-target', f'{platform.machine()}-apple-macosx13.0']
source = (root / 'Examples/MultiCloud/main.swift').read_text()
cases = {
    'azure_cpu': source.replace('size: AzureVMSize<X86_64>.standardB2s', 'size: AzureVMSize<ARM64>.standardD2psV5'),
    'google_cpu': source.replace('machineType: GoogleMachineType<X86_64>.e2Small', 'machineType: GoogleMachineType<ARM64>.t2aStandard1'),
    'google_region': source.replace('GoogleZone<AsiaNortheast1>("asia-northeast1-a")', 'GoogleZone<USCentral1>("us-central1-a")'),
    'cross_cloud_subnet': source.replace('subnet: googleSubnet, zone:', 'subnet: azureSubnet, zone:'),
    'azure_required_key': source.replace(', sshPublicKey: sshKey.value', ''),
}
# Change only the NSG's network, leaving the NIC subnet intact.
for kind, extra, network_args in [
    ('network', 'enum OtherNetwork: NetworkScope {}\n', 'group: rg, scope: OtherNetwork.self'),
    ('region', 'let otherRG = AzureResourceGroup("other_rg", resourceGroupName: "other", region: EastUS.self, provider: azure)\n', 'group: otherRG, scope: AzureNetwork.self'),
    ('subscription', 'enum OtherSubscription: AzureSubscriptionScope {}\nlet otherProvider = AzureProvider(subscriptionID: "other", scope: OtherSubscription.self, alias: "other")\nlet otherRG = AzureResourceGroup("other_rg", resourceGroupName: "other", region: JapanEast.self, provider: otherProvider)\n', 'group: otherRG, scope: AzureNetwork.self'),
]:
    group, scope = network_args.split(', scope: ')
    extra += f'let otherNetwork = AzureVirtualNetwork("other", networkName: "other", {group}, cidr: try IPv4CIDR("10.3.0.0/16"), scope: {scope})\n'
    cases['azure_' + kind] = source.replace('let nsg =', extra + 'let nsg =').replace('securityGroupName: "nido-nsg", network: vnet', 'securityGroupName: "nido-nsg", network: otherNetwork')
for kind, extra, provider, scope in [
    ('network', 'enum OtherNetwork: NetworkScope {}\n', 'google', 'OtherNetwork.self'),
    ('project', 'enum OtherProject: GoogleProjectScope {}\nlet otherProvider = GoogleProvider(project: "other", scope: OtherProject.self, alias: "other")\n', 'otherProvider', 'GCPNetwork.self'),
]:
    extra += f'let otherNetwork = GoogleNetwork("other", networkName: "other", provider: {provider}, scope: {scope})\n'
    cases['google_' + kind] = source.replace('let firewall =', extra + 'let firewall =').replace('firewallName: "nido-https", network: network', 'firewallName: "nido-https", network: otherNetwork')
with tempfile.TemporaryDirectory() as tmp:
    for name, text in [('valid', source), *cases.items()]:
        path = pathlib.Path(tmp) / (name + '.swift')
        path.write_text(text)
        result = subprocess.run(command + [str(path)], text=True, capture_output=True)
        if name == 'valid':
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode != 0 and 'no such module' not in result.stderr, (name, result.stderr)
            assert any(message in result.stderr for message in ['cannot convert', 'conflicting arguments', 'missing argument']), result.stderr
        print('PASS', name)
