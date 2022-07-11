---
title: "Static Webapps Functions and App Insights"
date: 2022-07-24T08:13:24+02:00
draft: true
comment_id: 3
showtoc: true
---

(Work in Progress)

### Adding App Settings
To hide our e-mail credentials, we can either upload them to Azure Key Vault or set them directly in the configuration. As this is a small application and there's no need to manage access to these secrets, we will set them directly in the configuration.

```Bicep
resource staticWebApp 'Microsoft.Web/staticSites@2021-03-01' = {
  // name, location, tags, sku, properties

  resource appconfig 'config@2021-03-01' = {
    name: 'appsettings'
    properties: {
      'APPINSIGHTS_INSTRUMENTATIONKEY': instrumentationKey
      'SENDER_ADDRESS': senderAddress
      'MJ_ID': mailjetId
      'MJ_SECRET': mailjetSecret
    }
  }
}
```