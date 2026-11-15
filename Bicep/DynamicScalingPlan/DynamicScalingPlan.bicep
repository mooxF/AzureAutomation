@description('The name of the Scaling plan to be created.')
param scalingPlanName string

@description('The description of the Scaling plan to be created.')
param scalingPlanDescription string = ''

@description('The location where the resources will be deployed.')
param location string

@description('The friendly name of the Scaling plan to be created.')
param friendlyName string = ''

@description('The host pool type of the Scaling plan to be created.')
@allowed([
  'Pooled'
  'Personal'
])
param hostPoolType string

@description('Scaling plan autoscaling triggers and Start/Stop actions will execute in the time zone selected.')
param timeZone string

@description('The schedules of the Scaling plan to be created.')
param schedules array

@description('The array of host pool resourceId with enabled flag.')
param hostpoolReferences array = []

@description('The name of the tag associated with the VMs that will be excluded from the Scaling plan.')
param exclusionTag string = ''

@description('The tags to be assigned to the Scaling plan.')
param tags object = {}

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingplans@2024-04-03' = {
  name: scalingPlanName
  location: location
  tags: tags
  properties: {
    friendlyName: friendlyName
    description: scalingPlanDescription
    hostPoolType: hostPoolType
    timeZone: timeZone
    exclusionTag: exclusionTag
    schedules: schedules
    hostPoolReferences: hostpoolReferences
  }
}

