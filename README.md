# RGCOPY

RGCOPY (**R**esource **G**roup **COPY**) is a tool that copies the most important resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). It can copy a whole landscape consisting of many servers within a single Azure resource group to a new resource group. The target RG might be in a different region or subscription. RGCOPY has been tested on **Windows**, **Linux** and in **Azure Cloud Shell**.

The following example demonstrates the user interface of RGCOPY

```powershell
$rgcopyParameter = @{
    sourceRG        = 'sap_vmss_zone'
    targetRG        = 'sap_vmss_zone_copy'
    targetLocation  = 'eastus'
    setVmSize       = 'Standard_E4ds_v4'
    setDiskSku      = 'Premium_LRS'
}
.\rgcopy.ps1 @rgcopyParameter
```

!["RGCOPY"](/images/RGCOPY.png)

RGCOPY has been developed for copying an SAP landscape and testing Azure with SAP workload. Therefore, it supports the most important Azure resources needed for SAP, for example **VMs**, **disks**, **load balancers**, storage accounts including content of **containers** and **shares**.

>:memo: **Note:** The list of supported Azure resources is maintained in the RGCOPY documentation: **[https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md#Supported-Azure-Resources](./rgcopy-docu.md#Supported-Azure-Resources)**

## Examples
The following examples show the usage of RGCOPY. In all examples, a source RG with the name 'SAP_master' is copied to the target RG 'SAP_copy'. For better readability, the examples use parameter splatting, see <https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_splatting>. Before starting RGCOPY, you must run the PowerShell cmdlet `Connect-AzAccount`.

```powershell
# connect to Azure
Update-AzConfig -EnableLoginByWam $true
Connect-AzAccount `
    -AuthScope 'Storage' `
    -TenantId '7b5ebd57-e5fd-445f-a920-55897cd71921' `
    -Subscription 'Contoso Subscription'


# start RGCOPY using cached credentials
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

You might have cached credentials for different subscriptions and users. In this case, you must specify user and subscription using RGCOPY parameters:


```powershell
$rgcopyParameter = @{
    # parameters for subscription and user 
    sourceSub       = 'Contoso Subscription'
    sourceSubUser   = 'user@contoso.com'
    sourceSubTenant = '7b5ebd57-e5fd-445f-a920-55897cd71921'

    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

You can store often used parameters in a separate parameter file and pass the filename to RGCOPY. The example above looks like this when having the parameter file `parameterFiles\contoso.json` 

```powershell
$rgcopyParameter = @{
    # using a parameter file
    parameterFile   = 'parameterFiles\contoso.json'

    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

```json
{
    // file 'parameterFiles\contoso.json'
    "sourceSub": "Contoso Subscription",
    "sourceSubUser": "user@contoso.com",
    "sourceSubTenant": "7b5ebd57-e5fd-445f-a920-55897cd71921",

    "targetSub": "Contoso Subscription",
    "targetSubUser": "user@contoso.com",
    "targetSubTenant": "7b5ebd57-e5fd-445f-a920-55897cd71921"
}
```

You can change almost all properties of VMs and disks in the target RG. The following example changes the VM size to Standard_M16ms (for VMs HANA1 and HANA2), Standard_M8ms (for VM SAPAPP) and Standard_D2s_v4 (for all other VMs):
```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    setVmSize = @(
        'Standard_M16ms @ HANA1, HANA2',
        'Standard_M8ms @ SAPAPP',
        'Standard_D2s_v4'
    )	
}
.\rgcopy.ps1 @rgcopyParameter
```

## Using RGCOPY for copying SAP systems

I'm frequently asked by SAP customers whether it's a good idea to use RGCOPY for moving their SAP landscape to a different region. The answer is: **it depends**. Actually, we are using RGCOPY for moving our SAP test landscapes. However, one should consider the following: <ul><li>RGCOPY performs a *copy*, not a *move*. Therefore, the SAP license becomes invalid. RGCOPY is not an SAP deployment tool. It just copies Azure resources. It does not change anything inside the VMs like changing the server name at the OS level or applying SAP license keys. </li><li> RGCOPY copies resources of a single Azure Resource Group. By default, it also copies the virtual network (to a new virtual network). Therefore, you cannot simply copy a landscape that is distributed over different resource groups and networks.</li><li> The resource types that are supported by RGCOPY is limited. Unsupported resources are not copied.</li><li> The downtime of a productive system would be quite huge because disk copy to a different region might take a whole day. If you just want to make a copy from production to a test system then downtime is very short: You just need to stop your productive servers for creating the disk snapshots.</li><li> Since it is a *copy* you might simply try RGCOPY. First of all, you should start RGCOPY with the parameter `simulate`. Hereby, you can detect possible issues: RGCOPY checks whether the used VM sizes are available in the target region and zone for your subscription. Furthermore, you can see whether the subscription quota (of VM families, total CPUs and disks) is sufficient. </li><li> You might use RGCOPY just for copying all disks (in parallel). For this, use the RGCOPY parameter `justCopyDisks`</li></ul> 

>:memo: **Note:** Be aware, that RGCOPY has been developed and is maintained by a single person. It is an open source tool, not an official Microsoft product. You can report bugs using GitHub Issues but you will not get help from Microsoft Product Support.

## Open Source version of RGCOPY
RGCOPY has been released as Open Source Software (OSS) in
- **https://github.com/Azure/RGCOPY**

The documentation of the OSS version is available here:

- **[https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md](./rgcopy-docu.md)** 

There also exists a Microsoft internal version of RGCOPY with additional features. It is stored in a different repository. 

## YouTube training
You can watch an introduction to RGCOPY on YouTube (22:35):

[![RGCOPY](https://i.ytimg.com/vi/8pCN10CRXtY/hqdefault.jpg)](https://www.youtube.com/watch?v=8pCN10CRXtY)


## Trademarks
This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.

