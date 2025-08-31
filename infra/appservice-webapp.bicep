// infra/appservice-webapp.bicep

@description('Name of the Web App (must be globally unique).')
param appName string

@description('Azure location for resources.')
param location string = resourceGroup().location

@description('App Service Plan name.')
param planName string = '${appName}-plan'

@description('App Service Plan SKU name (e.g., B1, P1v3).')
param planSkuName string = 'B1'

@description('App Service Plan SKU tier (Basic, PremiumV3 etc).')
param planSkuTier string = 'Basic'

@description('Full container image reference including tag OR digest, e.g. "chirag095.jfrog.io/petclinic-docker-dev-local/spring-petclinic:git-abc1234" OR "...@sha256:<digest>"')
param containerImage string

@description('JFrog Docker registry base URL, e.g. "https://chirag095.jfrog.io"')
param registryUrl string

@description('JFrog registry username (service account recommended).')
param registryUsername string

@secure()
@description('JFrog registry password / access token.')
param registryPassword string

@description('Container listening port (Spring Petclinic uses 8080).')
param port int = 8080

@description('Enable AlwaysOn (recommended for non-F1/D1 plans).')
param alwaysOn bool = true

// App Service Plan (Linux)
resource plan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: planName
  location: location
  sku: {
    name: planSkuName
    tier: planSkuTier
    size: planSkuName
    capacity: 1
  }
  properties: {
    reserved: true // Linux
  }
}

// Web App for Containers (Linux)
resource site 'Microsoft.Web/sites@2023-01-01' = {
  name: appName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Web/site configuration
    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerImage}'
      alwaysOn: alwaysOn
      http20Enabled: true
      // Set these on siteConfig (not top-level)
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
}

// App settings as a child resource (use parent: site)
resource appSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  name: 'appsettings'
  parent: site
  properties: {
    WEBSITES_PORT: string(port)

    // Private registry auth for JFrog (injected from workflow parameters)
    DOCKER_REGISTRY_SERVER_URL: registryUrl
    DOCKER_REGISTRY_SERVER_USERNAME: registryUsername
    DOCKER_REGISTRY_SERVER_PASSWORD: registryPassword

    // No persistent storage needed for container
    WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
  }
}

// Output the app URL
output webAppUrl string = 'https://${site.properties.defaultHostName}'
