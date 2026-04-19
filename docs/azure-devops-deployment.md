# Deploy Weather Function App via Azure DevOps

Step-by-step guide to set up a CI/CD pipeline in Azure DevOps that builds, tests, and deploys the Weather Function App (`weatherk71j-func`) to Azure Functions (Flex Consumption, Python 3.11).

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Azure DevOps organization | With a project created |
| Azure subscription | The subscription hosting the Function App |
| Service Connection | Azure Resource Manager connection to the subscription |
| Function App | Already provisioned via Terraform (`weatherk71j-func` or your equivalent) |
| Repo | `azure-function-server/` code pushed to an Azure DevOps Git repo (or GitHub with a service connection) |

---

## Step 1: Create an Azure Resource Manager Service Connection

1. In Azure DevOps, go to **Project Settings** → **Service connections**
2. Click **New service connection** → **Azure Resource Manager**
3. Select **Service principal (automatic)** or **Service principal (manual)** if using the existing SP
4. Configure:
   - **Subscription**: Select your subscription (`ME-MngEnvMCAP687688-surep-1`)
   - **Resource Group**: `rg-hybrid-agent`
   - **Service connection name**: `azure-hybrid-agent` (you'll reference this in the pipeline)
5. Check **Grant access permission to all pipelines** (or scope later)
6. Click **Save**

> **If using the existing SP (manual)**: Use Client ID `dfe36927-3171-4c66-8370-26840f0ab080`, Tenant ID `5d0245d3-4d99-44f5-82d3-28c83aeda726`, and the client secret. Verify the SP has **Contributor** on the resource group.

---

## Step 2: Push the Code to Azure DevOps Repos

Ensure the repository has this structure at minimum:

```
azure-function-server/
├── function_app.py
├── host.json
├── requirements.txt
├── test_function_app.py
└── weather_openapi.json
```

> `local.settings.json` should be in `.gitignore` — it contains local-only settings and must not be deployed.

Add to `.gitignore` if not already present:

```
local.settings.json
.python_packages/
__pycache__/
.venv/
```

---

## Step 3: Create the Pipeline YAML

Create `azure-function-server/azure-pipelines.yml` in your repo:

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - azure-function-server/**

pool:
  vmImage: 'ubuntu-latest'

variables:
  azureSubscription: 'azure-hybrid-agent'          # Service connection name from Step 1
  functionAppName: 'weatherk71j-func'               # Your Function App name
  resourceGroupName: 'rg-hybrid-agent'
  workingDirectory: 'azure-function-server'
  pythonVersion: '3.11'

stages:

# ════════════════════════════════════════════════════════════════
# Stage 1: Build & Test
# ════════════════════════════════════════════════════════════════
- stage: Build
  displayName: 'Build & Test'
  jobs:
  - job: BuildJob
    displayName: 'Build Function App'
    steps:

    - task: UsePythonVersion@0
      displayName: 'Use Python $(pythonVersion)'
      inputs:
        versionSpec: '$(pythonVersion)'

    - script: |
        cd $(workingDirectory)
        python -m pip install --upgrade pip
        pip install -r requirements.txt
        pip install pytest
      displayName: 'Install dependencies'

    - script: |
        cd $(workingDirectory)
        python -m pytest test_function_app.py -v --junitxml=test-results.xml
      displayName: 'Run unit tests'

    - task: PublishTestResults@2
      displayName: 'Publish test results'
      condition: succeededOrFailed()
      inputs:
        testResultsFiles: '$(workingDirectory)/test-results.xml'
        testRunTitle: 'Weather Function Unit Tests'

    - script: |
        cd $(workingDirectory)
        pip install -r requirements.txt --target=".python_packages/lib/site-packages"
      displayName: 'Install packages for deployment'

    - task: ArchiveFiles@2
      displayName: 'Create deployment zip'
      inputs:
        rootFolderOrFile: '$(workingDirectory)'
        includeRootFolder: false
        archiveType: 'zip'
        archiveFile: '$(Build.ArtifactStagingDirectory)/$(functionAppName).zip'
        replaceExistingArchive: true
        # Exclude test files and local settings from the package
        verbose: true

    - script: |
        cd $(Build.ArtifactStagingDirectory)
        python -c "
        import zipfile, os
        exclude = {'test_function_app.py', 'local.settings.json', '__pycache__', '.pytest_cache', 'test-results.xml'}
        src = '$(functionAppName).zip'
        dst = '$(functionAppName)-clean.zip'
        with zipfile.ZipFile(src, 'r') as zin, zipfile.ZipFile(dst, 'w') as zout:
            for item in zin.infolist():
                if not any(ex in item.filename for ex in exclude):
                    zout.writestr(item, zin.read(item.filename))
        os.replace(dst, src)
        "
      displayName: 'Remove test files from package'

    - publish: '$(Build.ArtifactStagingDirectory)/$(functionAppName).zip'
      artifact: 'functionapp'
      displayName: 'Publish artifact'

# ════════════════════════════════════════════════════════════════
# Stage 2: Deploy
# ════════════════════════════════════════════════════════════════
- stage: Deploy
  displayName: 'Deploy to Azure'
  dependsOn: Build
  condition: succeeded()
  jobs:
  - deployment: DeployJob
    displayName: 'Deploy Function App'
    environment: 'production'
    strategy:
      runOnce:
        deploy:
          steps:

          - task: AzureFunctionApp@2
            displayName: 'Deploy to $(functionAppName)'
            inputs:
              connectedServiceNameARM: '$(azureSubscription)'
              appType: 'functionAppLinux'
              appName: '$(functionAppName)'
              package: '$(Pipeline.Workspace)/functionapp/$(functionAppName).zip'
              runtimeStack: 'PYTHON|3.11'
              deploymentMethod: 'auto'
```

---

## Step 4: Configure the Pipeline in Azure DevOps

1. Go to **Pipelines** → **New pipeline**
2. Select your repo source (Azure Repos Git or GitHub)
3. Choose **Existing Azure Pipelines YAML file**
4. Set path to `/azure-function-server/azure-pipelines.yml`
5. Click **Run** to trigger the first build

---

## Step 5: Set Up an Environment with Approval Gate (Optional)

To require manual approval before deploying to production:

1. Go to **Pipelines** → **Environments**
2. Click on `production` (created automatically by the pipeline's first run)
3. Click the **⋮** menu → **Approvals and checks**
4. Add **Approvals** → select the approver(s)
5. Future runs will pause at the Deploy stage until approved

---

## Step 6: Verify the Deployment

After the pipeline completes:

```powershell
# Health check
curl https://weatherk71j-func.azurewebsites.net/api/healthz

# Weather endpoint (requires EasyAuth token)
$token = az account get-access-token --resource dfe36927-3171-4c66-8370-26840f0ab080 --query accessToken -o tsv
curl -H "Authorization: Bearer $token" "https://weatherk71j-func.azurewebsites.net/api/weather?city=Seattle"
```

---

## Pipeline Behavior

| Trigger | What happens |
|---------|-------------|
| Push to `main` touching `azure-function-server/**` | Full build → test → deploy |
| Push to other branches | No pipeline run (configure PR triggers separately) |
| Tests fail | Deploy stage is skipped |
| Approval gate set | Deploy pauses until approved |

---

## Adding PR Validation (Optional)

Add a separate trigger for pull request validation that only builds and tests (no deploy):

```yaml
pr:
  branches:
    include:
      - main
  paths:
    include:
      - azure-function-server/**
```

The `Deploy` stage already has `condition: succeeded()` and depends on `Build`, so PR runs will build and test but the deployment environment approval will block accidental deploys from PRs.

---

## Troubleshooting

### "No package found with specified pattern"

The artifact name or zip filename doesn't match. Verify the `publish` artifact name (`functionapp`) matches the download path in the deploy stage.

### Deployment succeeds but Function returns 500

- Check **Function App** → **Log stream** in the Azure Portal
- Verify `requirements.txt` includes all dependencies (currently just `azure-functions`)
- Ensure `.python_packages/` was packaged correctly in the zip

### "Could not find a Python version that satisfies the requirement"

The `UsePythonVersion` task version must match the Function runtime. This Function uses **Python 3.11** — make sure `pythonVersion: '3.11'` is set.

### Authentication errors (401)

EasyAuth is configured on this Function App. The pipeline deploys code only — EasyAuth settings are preserved. If EasyAuth was removed, reconfigure it:

```powershell
az webapp auth microsoft update --name weatherk71j-func `
    --resource-group rg-hybrid-agent `
    --client-id dfe36927-3171-4c66-8370-26840f0ab080 `
    --issuer "https://sts.windows.net/5d0245d3-4d99-44f5-82d3-28c83aeda726/"

az webapp auth update --name weatherk71j-func `
    --resource-group rg-hybrid-agent `
    --enabled true --action Return401
```

### Flex Consumption cold start after deploy

Flex Consumption instances scale to zero. The first request after deployment may take 5-10 seconds. The health check endpoint (`/api/healthz`) can be used as a warm-up probe.
