param customDomains array = []
param location string = resourceGroup().location

resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  name: 'helloWorld'
  location: location
  tags: {}
  sku: {
    name: 'Free'
    tier: 'Free'
  }

  properties: {
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
  resource domains 'customDomains@2021-03-01' = [for fqdn in customDomains: {
    name: fqdn
  }]
}

output defaultHostname string = staticWebApp.properties.defaultHostname
