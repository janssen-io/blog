---
title: "Static Web Apps with Azure DevOps"
date: 2022-07-10T08:22:57+02:00
draft: false
comment_id: 1
showtoc: true
---

Azure Static Web Apps can automatically generate a GitHub workflow and set the secret for you in GitHub. To deploy such an app via Azure DevOps, however, requires a bit more work.

In this post, I will show you how to setup the infrastructure for a static webapp and how to setup a custom domain with Azure Pipelines.

### Other posts in this series
- Static Web Apps with Azure DevOps (you are here)
- Static Web Apps with Azure DevOps - Part 2 (2022-07-17)
- Static Web Apps: Integrated Functions and App Insights (2022-07-24)
- Static Web Apps: Pull Request integration (2022-07-31)

## Solution
The website we will create will be a simple 'Hello World'-type website; A single html page with a contact form. For a more complex front-end, I suggest starting with the tutorials on [Microsoft Docs](https://docs.microsoft.com/en-us/azure/static-web-apps/deploy-nextjs).

Our website will be hosted on _www.example.com_ with an API at _www.example.com/api/sendMail_. 
The pipeline will first create the resource in a resource group,
setup the domain and then deploy the code.

## Repository structure
Let's start with the code for our little website.

To keep things easy to find, we'll setup the following file tree:

```txt
/
├─┬ .azuredevops
│ ├── ci.yml
├─┬ api
│ ├── host.json
│ ├── local.settings.json
│ ├── package.json
│ ├─┬ sendMail
│ │ ├── function.json
│ │ ├── index.js
├─┬ infra
│ ├── website.bicep
│ ├── dns.bicep
├─┬ src
│ ├── index.html
│ ├── style.css
```

* Our Azure Pipeline definition `ci.yml` will be put in the `.azuredevops` directory.
* Our Azure Functions will be created in the `api` directory.
* The Bicep templates will be put in the `infra` directory.
* And finally, the source for the static website will be loaded from the `src` directory.

The contents of all the files can be seen on [GitHub](TODO).
In this post we will only discuss the contents of the Bicep template and the YAML pipeline.

## Resource definition
Our static web app has a two requirements:
- It must be hosted at the custom domain 'www.example.com' (this post)
- It must send e-mails without exposing credentials to the public (third post)

Let's start with a very basic Bicep template and expand from there:

```Bicep
param location string = resourceGroup().location

resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  name: 'helloWorld'
  location: location
  tags: {}
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {}
}
```

The template above will create a new free Azure Static Web App in our resource group with the name 'helloWorld'. 

> #### How does it know which resource group to deploy to? 
> That's defined by the way you deploy it. When using the [Azure Resource Manager Template Deployment Task](https://github.com/microsoft/azure-pipelines-tasks/blob/master/Tasks/AzureResourceManagerTemplateDeploymentV3/README.md), we specify the name of the resource group to deploy to. Similarly, when using [Azure CLI](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli) or [Azure PowerShell](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-powershell) we pass the name of the resource group along with the filename of the template.

To ensure Azure does not create a GitHub Workflow, we can set the build property `skipGithubActionWorkflowGeneration` to true:

```Bicep
resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  // name, location, tags, sku

  properties: {
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
}
```

### Adding a custom domain
A custom domain is a subresource of the static webapp. We can define it either as a nested resource or as a separate resource.
I personally find it easiest to use a nested resource, so that's what we will do here!

```Bicep
param location string = resourceGroup().location
param customDomains array = []

resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  // name, location, tags, sku, properties

  resource domains 'customDomains@2021-03-01' = [for fqdn in customDomains: {
    name: fqdn
  }]
}

output defaultHostname string = staticWebApp.properties.defaultHostname
```

We just add a nested resource of the type `Microsoft.Web/staticSites/customDomains`. As it is a nested resource, we do not need to define the parent type.
I think this is great and makes the template significantly more readable. Especially when adding more sibling resources!

Just in case we want to use multiple domains later, we use an array parameter.
During the initial setup we can leave out the custom domain and once we setup the DNS records we can pass them and redeploy the static web app.

> #### Alternative Domain Validation method
> The [docs](https://docs.microsoft.com/en-us/azure/static-web-apps/custom-domain) show that simply setting up your CNAME record is sufficient.
> You might prefer to set a validation token in a TXT record instead.  This allows you to use a proxy such as CloudFlare to shield our origin server.
> No matter how we reach our static web app, Azure can then always validate the domain is ours.
>
> ```
> resource examplecomDomain 'customDomains@2021-03-01' = {
>   name: 'www.example.com'
>   properties: {
>     validationMethod: 'dns-txt-token'
>   }
> }
> ```
>
> You can then read the output token by setting an additional output value:
> ```
> output validationToken string = staticWebApp::examplecomDomain.properties.validationToken
> ```
>
> Unfortunately, deploying a custom domain this way using a Bicep template results in a catch 22; the deployment will halt until the domain is validated, but to validate the domain you need the token returned by a successful deployment. So for now, we'll validate our domain using CNAME delegation instead.

Finally we define a single output values: `defaultHostname`.
The default hostname is where we can currently reach our static web app. We will need this value to setup the CNAME record for the custom domain. By specifying them as output values we can easily use them in our pipeline. 

## Pipeline definition
Our pipeline will be responsible for four tasks:

1. [Create the Static Web App resource](#create-the-static-web-app-resource)
2. [Setup the DNS records](#setup-the-dns-records)
1. [Setup the custom domain](#setup-the-custom-domain)
3. [Build and test our code](#build-and-test-our-code)
4. [Deploy the code](#deploy-the-code)

### Create the Static Web App resource
Assuming we've setup our [Azure service connection](https://docs.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints?view=azure-devops&tabs=yaml),
we can immediately jump into our pipeline: `.azuredevops/ci.yml`.

```yaml
stages:
- stage: deploy_infra 
  displayName: Deploy Infrastructure
  jobs:
  - job: deploy_infra
    displayName: Deploy SWA and Update DNS
    steps:
    - task: AzureResourceManagerTemplateDeployment@3
      displayName: Create Static Web App
      inputs:
        connectedServiceName: myAzureServiceConnection
        action: Create Or Update Resource Group
        resourceGroupName: staticapp-demo
        location: westeurope
        templateLocation: Linked artifact
        csmFile: ../infra/website.bicep
        deploymentMode: Incremental
        deploymentOutputs: websiteOutput

    - pwsh: |
        $outputs = '$(websiteOutput)' | ConvertFrom-Json
        $outputs.PSObject.Properties | ForEach-Object {
          Write-Output "##vso[task.setvariable variable=$_.Name]$_.Value.value"
        }
      displayName: Capture ARM output as variables
```

We start by defining a new stage and job to deploy our infrastructure. If later we want to choose to skip deploying the 
infrastructure, then stages are the perfect tool to support this. Alternatively, we could have put this in a separate pipeline.

Then we use the `AzureResourceGroupDeployment` task to compile and apply our Bicep template. The most important arguments are:

- `connectedServiceName`: the name of our service connection
- `deploymentOutputs`: the name of the variable that will store the outputs, as defined in the bicep file, as a JSON string.

Afterwards, we take the `deploymentOutputs` stored in `websiteOutput` and convert every individual output (only `defaultHostname` in this example) to their own variable.

### Setup the DNS Records
Now that we have created the Static Web App and know the Azure generated hostname,
we can create the records at our DNS provider.
Below, I'll give two examples: [CloudFlare](#cloudflare) and [Azure DNS](#azure-dns). There are many other DNS providers out there that have similar APIs, but I can't cover them all!

#### Azure DNS
Using Azure DNS is the simplest solution, because we can use another Bicep file! This will take care of creating the
records if they do not exist yet or updating them if they have changed. Consider the following file (`infra/dns.bicep`):

```Bicep
@description('The hostname generated by Azure for the Static Web App')
param defaultHostname string

resource zone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: 'example.com'
  location: 'global'

  resource cnameRecord 'CNAME@2018-05-01' = {
    name: 'www'
    properties: {
      TTL: 3600
      CNAMERecord: {
        cname: defaultHostname
      }
    }
  }
}
```

To deploy this template, we add one more step below our PowerShell step.
This step is similar to the deployment of the Static Web App.
Except that we added `overrideParameters` to pass the recently obtained 
`defaultHostname` variables to the template.
Also, we don't need any outputs from this deployment, so we omit the 
`deploymentOutputs` argument.

```yaml
# ...
    - task: AzureResourceManagerTemplateDeployment@3
      # ...
    - pwsh:
      # ...
    - task: AzureResourceManagerTemplateDeployment@3
      displayName: Create DNS records
      inputs:
        connectedServiceName: myAzureServiceConnection
        action: Create Or Update Resource Group
        resourceGroupName: staticapp-demo
        location: westeurope
        templateLocation: Linked artifact
        csmFile: ../infra/dns.bicep
        overrideParameters: '-defaultHostname "$(defaultHostname)"'
        deploymentMode: Incremental
```

#### CloudFlare
Setting or updating records at CloudFlare is a little trickier. We first need to check if the records already exist.
If so, we can update them when the values have changed. If not, then we can simply create them.

First, to safely access CloudFlare, I setup my API credentials (`CF_Email` and `CF_API_Key`, `CF_Zone`) as secure variables in a [variable group](https://docs.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups?view=azure-devops&tabs=yaml). Then we can use them in our pipeline by referencing the group under `variables` in our `deploy_infra` job.

```yaml
stages:
- stage: deploy_infra 
  displayName: Deploy Infrastructure
  jobs:
  - job: deploy_infra
    displayName: Deploy SWA and Update DNS
    variables:
      - group: swa_secrets
    steps:
      # ...
```

To perform the steps listed above, we can use the following [API endpoints](https://api.cloudflare.com/#dns-records-for-a-zone-properties):

- [List DNS records](https://api.cloudflare.com/#dns-records-for-a-zone-list-dns-records): GET zones/:zone/dns_records  
- [Create DNS records](https://api.cloudflare.com/#dns-records-for-a-zone-list-dns-records): POST zones/:zone/dns_records
- [Patch DNS records](https://api.cloudflare.com/#dns-records-for-a-zone-patch-dns-record): PATCH zones/:zone/dns_records/:id

For this tutorial, we will use inline scripts, but of course you can put these scripts in separate files so they are easy to reuse.

Below our current steps, we'll add the following:

```yaml
    # ...
    steps:
    - task: AzureResourceManagerTemplateDeployment@3
      # ...
    - pwsh:
      # ...
    - task: AzureResourceManagerTemplateDeployment@3
      # ...
    - pwsh: |
        $url = "https://api.cloudflare.com/client/v4/zones/${{ variables.CF_Zone }}/dns_records?name=www.example.com
        $headers = @{
          "X-Auth-Email" = "${{ variables.CF_Email }}"
          "X-Auth-Key" = "${{ variables.CF_API_Key }}"
        }
        $records = Invoke-RestMethod `
          -Uri $url `
          -Headers $headers `
          -Method GET `
          -ContentType application/json `
          | ConvertFrom-Json

        $cnameRecords = $records.result | where { $_.Type -eq "CNAME" }

        if ($cnameRecords.Length -gt 0) {
          Write-Output "##vso[task.setvariable variable=formerCname]$cnameRecords[0].content"
          Write-Output "##vso[task.setvariable variable=cnameId]$cnameRecords[0].id"
        }

    - pwsh: |
        $url = "https://api.cloudflare.com/client/v4/zones/${{ variables.CF_Zone }}/dns_records
        $headers = @{
          "X-Auth-Email" = "${{ variables.CF_Email }}"
          "X-Auth-Key" = "${{ variables.CF_API_Key }}"
        }
        $body = @{
          "type" = "CNAME"
          "name" = "www.example.com"
          "content" = "$(defaultHostname)"
          "ttl" = 3600
          "proxied" = $True
        }
        Invoke-RestMethod `
          -Uri $url `
          -Headers $headers `
          -Method POST `
          -Body $body `
          -ContentType application/json
      displayName: Create new CNAME
      condition: and(succeeded(), eq(variables.formerCname, ''))

    - pwsh: |
        $url = "https://api.cloudflare.com/client/v4/zones/${{ variables.CF_Zone }}/dns_records/$(cnameId)"
        $headers = @{
          "X-Auth-Email" = "${{ variables.CF_Email }}"
          "X-Auth-Key" = "${{ variables.CF_API_Key }}"
        }
        $body = @{ "content" = "$(defaultHostname)" }
        Invoke-RestMethod `
          -Uri $url `
          -Headers $headers `
          -Method PATCH `
          -Body $body `
          -ContentType application/json
      displayName: Update CNAME
      condition: and(
        succeeded(),
        ne(variables.formerCname, ''),
        ne(variables.formerCname, variables.defaultHostname))
``` 
### Setup the custom domain
Now that we've setup the DNS record, we can redeploy our Static Web App with the custom domain.

```yaml
    # ...
    steps:
    - task: AzureResourceManagerTemplateDeployment@3
      # ...
    - pwsh:
      # ...
    - task: AzureResourceManagerTemplateDeployment@3
      # ...
    - pwsh:
      # ...
    - task: AzureResourceManagerTemplateDeployment@3
      displayName: Deploy Custom Domain
      inputs:
        connectedServiceName: myAzureServiceConnection
        action: Create Or Update Resource Group
        resourceGroupName: staticapp-demo
        location: westeurope
        templateLocation: Linked artifact
        csmFile: ../infra/website.bicep
        overrideParameters: '-customDomains ["www.example.com"]'
        deploymentMode: Incremental
        deploymentOutputs: websiteOutput
```

Alternatively, we could have deployed a smaller Bicep template with just the custom domain. I personally like to have one template for a resource and its child resources.

```Bicep
param customDomains array = []
param staticWebAppName string

resource domains 'Microsoft.Web/staticSites/customDomains@2021-03-01' = [for fqdn in customDomains: {
  name: '${staticWebAppName}/${fqdn}'
}]
```

And that's our first stage done! In the next post, we'll build, test and deploy our code. For an overview of the templates, you can checkout the source on GitHub:

- [website.bicep](./files/website.bicep)
- [dns.bicep](./files/dns.bicep)
- [ci.yml](./files/ci.yml)
