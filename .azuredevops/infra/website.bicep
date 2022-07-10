param name string
param location string = resourceGroup().location
param customDomains array = []

resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  name: name
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
output apiToken string = staticWebApp.properties.repositoryToken
