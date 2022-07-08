param location string = resourceGroup().location

resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  name: 'blog'
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

  resource wwwDomain 'customDomains@2021-03-01' = {
    name: 'www.janssen.io'
    properties: {
      validationMethod: 'dns-txt-token'
    }
  }
}

output defaultHostname string = staticWebApp.properties.defaultHostname
output validationToken string = staticWebApp::wwwDomain.properties.validationToken
