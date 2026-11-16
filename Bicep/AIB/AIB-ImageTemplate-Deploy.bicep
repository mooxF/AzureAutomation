
param customerCode string

param buildLocation string

param imageBuilderIdentityName string

param imageGalleryName string

param imageDefinitionName string

param imageTemplateName string

param runOutputName string

param replicationRegions array

param vmSize string = 'Standard_D4as_v5'

param osDiskSizeGB int = 127

param buildTimeoutInMinutes int = 180

//Source Image Params
@allowed([
  'PlatformImage'
  'SharedImageVersion'
])
param sourceType string = 'PlatformImage'

param sourceImageVersionId string = ''

param sourcePublisher string = 'MicrosoftWindowsDesktop'
param sourceOffer string = 'office-365'
param sourceSku string = 'win11-25h2-avd-m365'
param sourceVersion string = 'latest'

@description('Ordered list of PowerShell customizer objects. Scripts execute in array order.')
param customScripts array = []

var imageSource = sourceType == 'SharedImageVersion'
  ? {
      type: 'SharedImageVersion'
      imageVersionId: sourceImageVersionId
    }
  : {
      type: 'PlatformImage'
      publisher: sourcePublisher
      offer: sourceOffer
      sku: sourceSku
      version: sourceVersion
    }

// Existing Azure Image Builder managed identity
resource imageBuilderIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: imageBuilderIdentityName
}


// Existing Azure Compute Gallery
resource imageGallery 'Microsoft.Compute/galleries@2023-07-03' existing = {
  name: imageGalleryName
}


// Existing image definition
resource imageDefinition 'Microsoft.Compute/galleries/images@2023-07-03' existing = {
  parent: imageGallery
  name: imageDefinitionName
}


// Azure Image Builder template
resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2025-10-01' = {
  name: imageTemplateName
  location: buildLocation

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${imageBuilderIdentity.id}': {}
    }
  }

  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes

    vmProfile: {
      vmSize: vmSize
      osDiskSizeGB: osDiskSizeGB
    }

    source: imageSource

    ...(!empty(customScripts) ? {
    customize: customScripts
    } : {})

    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: imageDefinition.id
        runOutputName: runOutputName
        replicationRegions: replicationRegions
        excludeFromLatest: false
        artifactTags: {
          CreatedBy: 'AzureImageBuilder'
          Customer: customerCode
        }
      }
    ]
  }
}


// Outputs
output imageTemplateName string = imageTemplate.name

output imageTemplateId string = imageTemplate.id

output buildLocation string = buildLocation

output sourceImageVersionId string = sourceImageVersionId

output targetImageDefinitionId string = imageDefinition.id

output runOutputName string = runOutputName

output replicationRegions array = replicationRegions

output buildStatus string = 'Image template created/updated. Image build has not been started by this deployment.'
