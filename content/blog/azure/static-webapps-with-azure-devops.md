---
title: "Static Web Apps with Azure Devops"
date: 2022-07-06T20:22:57+02:00
draft: true
comment_id: 1
showtoc: true
---

Azure Static Web Apps can automatically generate a GitHub workflow and set the secret for you in GitHub. To deploy such an app via Azure DevOps, however, requires a bit more work.
In this post, I will show you how to setup continuous integration for a static webapp, setup a custom domain with Azure Pipelines.

In future posts, I will show how to add an integrated function and hook it up to Application Insights, test your changes before merging your Pull Request, Bring Your Own Functions and integration with Azure Front Door.

## Solution
The website we will create will be a simple 'Hello World'-type website; A single html page with a contact form. For a more complex front-end, I suggest starting with the tutorials on [Microsoft Docs](https://docs.microsoft.com/en-us/azure/static-web-apps/deploy-nextjs).

Our website will be hosted on _example.com_ with an API at _example.com/api/sendMail_. 
The pipeline will first create the resource in a resource group, including the domain, and then deploy the code. Finally it will update our DNS records to allow Azure to verify that we own the domain.

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
├─┬ src
│ ├── index.html
│ ├── style.css
```

* Our Azure Pipeline definition `ci.yml` will be put in the `.azuredevops` directory.
* Our Azure Functions will be created in the `api` directory.
* The Bicep template (or templates in the future) will be put in the `infra` directory.
* And finally, the source for the static website will be loaded from the `src` directory.

The contents of all the files can be seen on [GitHub](TODO).
In this post we will only discuss the contents of the Bicep template and the YAML pipeline.

## Resource definition
Our static web app has a two requirements:
- It must be hosted at the custom domain 'example.com' (this post)
- It must send e-mails without exposing credentials to the public ([next post]({{< ref "/blog/azure/static-webapps-functions-and-app-insights.md" >}} "Next Post"))

Let's start with a very basic Bicep template and expand from there:


```Bicep
resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  name: 'helloWorld'
  location: resourceGroup().location
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
> That's defined by the way you deploy it. When using the [Azure Resource Group Deployment Task](https://docs.microsoft.com/en-us/azure/devops/pipelines/tasks/deploy/azure-resource-group-deployment?view=azure-devops), we specify the name of the resource group to deploy to. Similarly, when using [Azure CLI](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli) or [Azure PowerShell](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-powershell) we pass the name of the resource group along with the filename of the template.

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
resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  // name, location, tags, sku, properties

  resource examplecomDomain 'customDomains@2021-03-01' = {
    name: 'example.com'
    properties: {
      validationMethod: 'dns-txt-token'
    }
  }
}

output defaultHostname string = staticWebApp.properties.defaultHostname
output validationToken string = staticWebApp::examplecomDomain.properties.validationToken
```

First we added a nested resource of the type `Microsoft.Web/staticSites/customDomains`. As it is a nested resource, we do not need to define the parent type.
I think this is great and makes the template significantly more readable. Especially when adding more sibling resources!

> #### What is this 'validationMethod'?
> The [docs](https://docs.microsoft.com/en-us/azure/static-web-apps/custom-domain) show that simply setting up your CNAME record is sufficient.
> I prefer to set a validation token in a TXT record instead.  This allows us to use a proxy such as CloudFlare to shield our origin server.
> No matter how we reach our static web app, Azure can then always validate the domain is ours.

Finally we define two output values: `defaultHostname` and `validationToken`.
These values are required to configure our DNS records for the custom domain. By specifying them as output values we can easily use them in our pipeline. 

## Pipeline definition
Our pipeline will be responsible for four tasks:

1. Create the Static Web App resource
2. Setup the DNS records in CloudFlare or Azure DNS (when not set yet)
3. Build and test our code
4. Deploy the code

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
    - task: AzureResourceGroupDeployment@2
      displayName: Create Static Web App
      inputs:
        azureSubscription: myAzureServiceConnection
        action: Create Or Update Resource Group
        resourceGroupName: staticapp-demo
        location: westeurope
        templateLocation: Linked artifact
        csmFile: ../infra/website.bicep
        deploymentMode: Incremental
        deploymentOutputs: websiteOutput

    - pwsh: |
        $outputs = "$(websiteOutput)" | ConvertFrom-Json
        $outputs.PSObject.Properties | ForEach-Object {
          Write-Output "##vso[task.setvariable variable=$_.Name]$_.Value.value"
        }
      displayName: Capture ARM output as variables
```

We start by defining a new stage and job to deploy our infrastructure. If later we want to choose to skip deploying the 
infrastructure, then stages are the perfect tool to support this. Alternatively, we could have put this in a separate pipeline.

Then we use the `AzureResourceGroupDeployment` task to compile and apply our Bicep template. The most important arguments are:

- `azureSubscription`: the name of our service connection
- `deploymentOutputs`: the name of the variable that will store the outputs, as defined in the bicep file, as a JSON string.

Afterwards, we take the `deploymentOutputs` stored in `websiteOutput` and convert every individual output (`defaultHostname` and `validationToken`)
to their own variable.

### Creating or updating DNS records
Now that we have created the Static Web App and know the Azure generated hostname and validation token, we can create the records at our DNS provider.
Below, I'll give two examples: [CloudFlare](#cloudflare) and [Azure DNS](#azure-dns). There are many other DNS providers out there that have similar APIs, but I can't cover them all!

#### Azure DNS
Using Azure DNS is the simplest solution, because we can use another Bicep file! This will take care of creating the
records if they do not exist yet or updating them if they have changed. Consider the following file (`infra/dns.bicep`):

```Bicep
@description('The hostname generated by Azure for the Static Web App')
param defaultHostname string

@description('The dns-txt-token provided by the Static Web App')
param validationToken string
            
resource zone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: 'example.com'
  location: 'global'

  resource cnameRecord 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
    name: 'www'
    properties: {
      TTL: 3600
      CNAMERecords: {
        cname: defaultHostname
      }
    }
  }

  resource validationRecord 'Microsoft.Network/dnsZones/TXT@2018-05-01' = {
    name: 'www'
    properties: {
      TTL: 3600
      TXTRecords: [
        {
          value: [
            validationToken
          ]
        }
      ]
    }
  }
}
```

To deploy this template, we add one more step below our PowerShell step.
This step is similar to the deployment of the Static Web App. Except that we added `overrideParameters` to pass the 
recently obtained `defaultHostname` and `validationToken` variables to the template.
Also, we don't need any outputs from this deployment, so we omit the `deploymentOutputs` argument.


```yaml
# ...
    - task: AzureResourceGroupDeployment@2
      # ...
    - pwsh:
      # ...
    - task: AzureResourceGroupDeployment@2
      displayName: Create DNS records
      inputs:
        azureSubscription: myAzureServiceConnection
        action: Create Or Update Resource Group
        resourceGroupName: staticapp-demo
        location: westeurope
        templateLocation: Linked artifact
        csmFile: ../infra/dns.bicep
        overrideParameters: '-defaultHostname "$(defaultHostname)" -validationToken "$(validationToken)"'
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