// Simple ETL with Azure Data Factory:
//   input/customers.csv --(Copy)--> output/raw/customers.csv --(Data Flow: age > 28)--> output/curated/customers_over_28.csv

@description('Azure region for all resources.')
param location string = resourceGroup().location

var suffix = uniqueString(resourceGroup().id)
var storageAccountName = 'stadfetl${suffix}'
var dataFactoryName = 'adf-etl-${suffix}'
// Built-in role: Storage Blob Data Contributor
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// ---------- Storage ----------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource inputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'input'
}

resource outputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'output'
}

// ---------- Data Factory ----------

resource factory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: dataFactoryName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {}
}

// Data Factory reaches storage with its managed identity: no keys or connection strings stored.
resource factoryBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, factory.id, blobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: factory.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobLinkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: factory
  name: 'ls_blob_storage'
  properties: {
    type: 'AzureBlobStorage'
    // No credential = authenticate with the factory's system-assigned managed identity.
    typeProperties: {
      serviceEndpoint: storage.properties.primaryEndpoints.blob
      accountKind: 'StorageV2'
    }
  }
}

// ---------- Datasets (all CSV with a header row) ----------

var csvFormat = {
  columnDelimiter: ','
  escapeChar: '\\'
  quoteChar: '"'
  firstRowAsHeader: true
}

resource customersInput 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: factory
  name: 'ds_customers_input'
  properties: {
    type: 'DelimitedText'
    linkedServiceName: { referenceName: blobLinkedService.name, type: 'LinkedServiceReference' }
    typeProperties: union(csvFormat, {
      location: { type: 'AzureBlobStorageLocation', container: inputContainer.name, fileName: 'customers.csv' }
    })
  }
}

resource customersRaw 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: factory
  name: 'ds_customers_raw'
  properties: {
    type: 'DelimitedText'
    linkedServiceName: { referenceName: blobLinkedService.name, type: 'LinkedServiceReference' }
    typeProperties: union(csvFormat, {
      location: { type: 'AzureBlobStorageLocation', container: outputContainer.name, folderPath: 'raw', fileName: 'customers.csv' }
    })
  }
}

// Folder only: the data flow sink names the output file.
resource customersCurated 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: factory
  name: 'ds_customers_curated'
  properties: {
    type: 'DelimitedText'
    linkedServiceName: { referenceName: blobLinkedService.name, type: 'LinkedServiceReference' }
    typeProperties: union(csvFormat, {
      location: { type: 'AzureBlobStorageLocation', container: outputContainer.name, folderPath: 'curated' }
    })
  }
}

// ---------- Mapping Data Flow: keep customers older than 28 ----------

resource filterDataFlow 'Microsoft.DataFactory/factories/dataflows@2018-06-01' = {
  parent: factory
  name: 'df_filter_customers_over_28'
  properties: {
    type: 'MappingDataFlow'
    typeProperties: {
      sources: [
        { name: 'RawCustomers', dataset: { referenceName: customersRaw.name, type: 'DatasetReference' } }
      ]
      sinks: [
        { name: 'CuratedCustomers', dataset: { referenceName: customersCurated.name, type: 'DatasetReference' } }
      ]
      transformations: [
        { name: 'FilterOver28' }
      ]
      scriptLines: [
        'source(output('
        '    id as integer,'
        '    name as string,'
        '    city as string,'
        '    age as integer'
        '  ),'
        '  allowSchemaDrift: false,'
        '  validateSchema: false,'
        '  ignoreNoFilesFound: false) ~> RawCustomers'
        'RawCustomers filter(age > 28) ~> FilterOver28'
        // allowSchemaDrift on the sink = auto-map every incoming column (the curated dataset has no fixed schema)
        'FilterOver28 sink(allowSchemaDrift: true,'
        '  validateSchema: false,'
        '  partitionFileNames:[\'customers_over_28.csv\'],'
        '  umask: 0022,'
        '  preCommands: [],'
        '  postCommands: [],'
        '  skipDuplicateMapInputs: true,'
        '  skipDuplicateMapOutputs: true,'
        '  partitionBy(\'hash\', 1)) ~> CuratedCustomers'
      ]
    }
  }
}

// ---------- Pipeline: Copy (land raw) -> Data Flow (filter) ----------

resource pipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: factory
  name: 'pl_customers_etl'
  properties: {
    activities: [
      {
        name: 'CopyRawCustomers'
        type: 'Copy'
        inputs: [ { referenceName: customersInput.name, type: 'DatasetReference' } ]
        outputs: [ { referenceName: customersRaw.name, type: 'DatasetReference' } ]
        typeProperties: {
          source: {
            type: 'DelimitedTextSource'
            storeSettings: { type: 'AzureBlobStorageReadSettings' }
            formatSettings: { type: 'DelimitedTextReadSettings' }
          }
          sink: {
            type: 'DelimitedTextSink'
            storeSettings: { type: 'AzureBlobStorageWriteSettings' }
            // Copy activity always quotes text values in delimited output (quoteAllText=false is unsupported).
            formatSettings: { type: 'DelimitedTextWriteSettings', fileExtension: '.csv', quoteAllText: true }
          }
        }
      }
      {
        name: 'FilterCustomersOver28'
        type: 'ExecuteDataFlow'
        dependsOn: [ { activity: 'CopyRawCustomers', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: {
          dataFlow: { referenceName: filterDataFlow.name, type: 'DataFlowReference' }
          // Smallest Spark cluster ADF offers; it shuts down right after the run.
          compute: { computeType: 'General', coreCount: 8 }
          traceLevel: 'Fine'
        }
      }
    ]
  }
}

output storageAccountName string = storage.name
output dataFactoryName string = factory.name
output pipelineName string = pipeline.name
