# Hybrid VNet AI Agent — Architecture Diagrams

## 1. High-Level Architecture

```mermaid
graph TB
    subgraph Internet["Internet / Public"]
        User["User (SSH Client)"]
        M365["Microsoft 365<br/>Teams / Outlook"]
        EntraID["Microsoft Entra ID<br/>Token Issuance"]
        FoundryAPI["AI Foundry Agent API<br/>aiservicesk71j.services.ai.azure.com"]
        WeatherFQDN["Weather Function FQDN<br/>weatherk71j-func.azurewebsites.net"]
        BotConnector["Bot Framework Connector<br/>smba.trafficmanager.net"]
    end

    subgraph VNet["agent-vnet (10.0.0.0/16)"]
        subgraph AgentSubnet["agent-subnet (10.0.0.0/24)"]
            DataProxy["AI Services<br/>Network Injection<br/>(Data Proxy)"]
        end

        subgraph PESubnet["pe-subnet (10.0.1.0/24)"]
            PE_AI["PE: AI Services"]
            PE_Blob["PE: Blob Storage"]
            PE_Cosmos["PE: Cosmos DB"]
            PE_Func["PE: Weather Function"]
            PE_Queue["PE: Queue Storage"]
            PE_File["PE: File Storage"]
        end

        subgraph MCPSubnet["mcp-subnet (10.0.2.0/24)"]
            CAE["Container Apps Environment<br/>Internal LB: 10.0.2.160"]
            MCPServer["DateTime MCP Server<br/>dtmcpk71j-app<br/>Streamable HTTP"]
        end

        subgraph FuncSubnet["func-integration-subnet (10.0.3.0/24)"]
            FuncVNet["Weather Function<br/>VNet Integration<br/>(Outbound)"]
        end

        subgraph JumpSubnet["jumpbox-subnet (10.0.4.0/24)"]
            JumpVM["jumpbox-vm<br/>Ubuntu 24.04 LTS<br/>10.0.4.4<br/>foundry_agent.py"]
        end

        subgraph AgentAppSubnet["agent-app-subnet (10.0.6.0/23)"]
            AgentCAE["Container Apps Environment<br/>External (internet-facing)"]
            AgentWebapp["Agent Webapp<br/>agentappk71j-app<br/>aiohttp + Microsoft Agents SDK"]
        end
    end

    subgraph Services["Azure PaaS Services"]
        AISvc["AI Services Account<br/>aiservicesk71j (S0)<br/>gpt-4.1-mini"]
        WeatherFunc["Weather Function App<br/>weatherk71j-func<br/>Flex Consumption (FC1)"]
        ACR["ACR: acrdtmcpk71j<br/>MCP + Agent Webapp Images"]
        Storage1["Storage: aiservicesk71jst<br/>Blob (AI data)"]
        Storage2["Storage: weatherk71jstor<br/>Blob + Queue + File"]
        Storage3["Storage: toolqk71jst<br/>Queue (Tool results)"]
        CosmosDB["Cosmos DB<br/>aiservicesk71jcosmosdb<br/>Thread Storage"]
    end

    subgraph Observability["Observability"]
        AppInsights["Application Insights<br/>hybrid-agent-k71j-appinsights"]
        LAW["Log Analytics Workspace<br/>hybrid-agent-k71j-law"]
    end

    User -->|"SSH TCP/22"| JumpVM
    JumpVM -->|"HTTPS + Bearer<br/>ai.azure.com scope"| FoundryAPI
    JumpVM -->|"Entra Token"| EntraID
    JumpVM -->|"HTTPS + EasyAuth Bearer"| WeatherFQDN
    JumpVM -->|"POST /mcp<br/>VNet Internal"| MCPServer

    M365 -->|"Bot Framework<br/>Activities"| BotConnector
    BotConnector -->|"POST /api/messages"| AgentWebapp
    AgentWebapp -->|"Foundry Assistants API<br/>(Managed Identity)"| FoundryAPI
    AgentWebapp -->|"HTTPS + MI Token<br/>EasyAuth"| WeatherFQDN
    AgentWebapp -->|"POST /mcp<br/>VNet Internal DNS"| MCPServer
    AgentWebapp -->|"Reply Activity"| BotConnector

    PE_AI -.->|"Private Link"| AISvc
    PE_Blob -.->|"Private Link"| Storage1
    PE_Cosmos -.->|"Private Link"| CosmosDB
    PE_Func -.->|"Private Link"| WeatherFunc
    PE_Queue -.->|"Private Link"| Storage3
    PE_File -.->|"Private Link"| Storage2

    ACR -.->|"Image Pull"| CAE
    ACR -.->|"Image Pull"| AgentCAE
    WeatherFunc -.->|"VNet Integration"| FuncVNet
    DataProxy -.->|"Network Injection"| AISvc

    AgentWebapp -.->|"Telemetry"| AppInsights
    WeatherFunc -.->|"Telemetry"| AppInsights
    MCPServer -.->|"Telemetry"| AppInsights
    AppInsights -.->|"Logs & Metrics"| LAW

    style VNet fill:#d0ebff,stroke:#1971c2,stroke-width:3px
    style AgentSubnet fill:#d0bfff,stroke:#6741d9
    style PESubnet fill:#eebefa,stroke:#9c36b5
    style MCPSubnet fill:#b2f2bb,stroke:#2f9e44
    style FuncSubnet fill:#ffec99,stroke:#f08c00
    style JumpSubnet fill:#ffd8a8,stroke:#e8590c
    style AgentAppSubnet fill:#c3fae8,stroke:#087f5b
    style Internet fill:#ffc9c9,stroke:#e03131
    style Services fill:#b2f2bb,stroke:#2f9e44
    style Observability fill:#fff3bf,stroke:#e67700
```

## 2. Component Diagram

```mermaid
graph TB
    subgraph ClientLayer["Client Layer"]
        SSH["SSH Client"]
        VM["Jump VM<br/>(foundry_agent.py)"]
        Teams["Microsoft Teams<br/>/ Outlook"]
    end

    subgraph M365Layer["M365 Integration Layer"]
        BotConnector["Bot Framework<br/>Connector Service"]
        AgentWebapp["Agent Webapp<br/>agentappk71j-app<br/>aiohttp + Microsoft Agents SDK v0.9.0"]
    end

    subgraph AgentLayer["Agent Orchestration Layer"]
        FoundryAgent["Foundry Agent 'pce'<br/>asst_fAVIpp16oVnfHaBuCo1BtvJ9"]
        GPT["gpt-4.1-mini<br/>GlobalStandard (cap=30)"]
    end

    subgraph ToolLayer["Tool Execution Layer (6 Function Tools)"]
        subgraph WeatherTools["Weather Tools (via Azure Function + EasyAuth)"]
            T1["get_weather — Current weather"]
            T2["get_forecast — Multi-day forecast"]
            T3["get_weather_alerts — Active alerts"]
        end
        subgraph DateTimeTools["DateTime Tools (via MCP Server)"]
            T4["get_current_datetime — Current time + TZ"]
            T5["convert_timezone — TZ conversion"]
            T6["calculate_time_difference — Time diff"]
        end
    end

    subgraph BackendLayer["Backend Services"]
        AISvc["AI Services Account<br/>S0 / Managed Identity Only"]
        FuncApp["Weather Function App<br/>Flex Consumption FC1"]
        ContainerApp["DateTime MCP Server<br/>Container App (Internal)"]
    end

    subgraph InfraLayer["Infrastructure (Terraform — 10 Modules)"]
        M1["network"]
        M2["ai-account"]
        M3["ai-project"]
        M4["dependent-resources"]
        M5["private-endpoints"]
        M6["weather-function"]
        M7["datetime-mcp"]
        M8["jump-vm"]
        M9["foundry-agent"]
        M10["app-insights"]
    end

    subgraph ObsLayer["Observability"]
        AppInsights["Application Insights<br/>hybrid-agent-k71j-appinsights"]
        LAW["Log Analytics Workspace<br/>hybrid-agent-k71j-law"]
        OTel["Azure Monitor<br/>OpenTelemetry SDK"]
    end

    subgraph SecurityLayer["Security Controls"]
        Entra["Entra ID Auth"]
        EasyAuth["EasyAuth (Return401)<br/>+ allowedApplications"]
        ManagedId["System-Assigned<br/>Managed Identity"]
        NSG["NSGs (NIC + Subnet)"]
        PE["Private Endpoints (6)"]
        DNS["Private DNS Zones (7+)"]
        NoSharedKey["shared_key: disabled"]
        NoLocalAuth["disableLocalAuth: true"]
    end

    SSH --> VM
    Teams --> BotConnector
    BotConnector --> AgentWebapp
    VM --> FoundryAgent
    AgentWebapp --> FoundryAgent
    FoundryAgent --> GPT
    FoundryAgent --> ToolLayer
    T1 & T2 & T3 --> FuncApp
    T4 & T5 & T6 --> ContainerApp
    FuncApp --> AISvc
    ContainerApp --> AISvc

    AgentWebapp -.->|"Telemetry"| OTel
    FuncApp -.->|"Telemetry"| OTel
    ContainerApp -.->|"Telemetry"| OTel
    OTel -.-> AppInsights
    AppInsights -.-> LAW

    style ClientLayer fill:#ffc9c9,stroke:#e03131
    style M365Layer fill:#c3fae8,stroke:#087f5b
    style AgentLayer fill:#d0ebff,stroke:#1971c2
    style ToolLayer fill:#b2f2bb,stroke:#2f9e44
    style WeatherTools fill:#ffec99,stroke:#f08c00
    style DateTimeTools fill:#d0bfff,stroke:#6741d9
    style BackendLayer fill:#eebefa,stroke:#9c36b5
    style InfraLayer fill:#f8f9fa,stroke:#868e96
    style ObsLayer fill:#fff3bf,stroke:#e67700
    style SecurityLayer fill:#ffd8a8,stroke:#e8590c
```

## 3. Data Flow — End-to-End Request

### 3a. Jump VM Flow (Direct CLI)

```mermaid
sequenceDiagram
    participant User as User (SSH)
    participant VM as Jump VM<br/>(foundry_agent.py)
    participant Entra as Microsoft Entra ID
    participant Foundry as AI Foundry API
    participant GPT as gpt-4.1-mini
    participant WFunc as Weather Function<br/>(EasyAuth)
    participant MCP as DateTime MCP<br/>(VNet Internal)

    Note over User,MCP: Phase 1: Authentication
    User->>VM: SSH (TCP/22 via Public IP)
    VM->>Entra: ClientSecretCredential<br/>(tenant, client_id, secret)
    Entra-->>VM: Access Token<br/>(ai.azure.com/.default)

    Note over User,MCP: Phase 2: Agent Interaction
    VM->>Foundry: POST /threads (Create Thread)
    Foundry-->>VM: thread_id
    VM->>Foundry: POST /threads/{id}/messages<br/>"What's the weather in Seattle<br/>and current time in Tokyo?"
    VM->>Foundry: POST /threads/{id}/runs<br/>(agent: asst_fAVIpp16oVnfHaBuCo1BtvJ9)

    Note over User,MCP: Phase 3: Tool Execution (Client-Side)
    Foundry->>GPT: Analyze message → select tools
    GPT-->>Foundry: requires_action:<br/>get_weather(city=Seattle)<br/>get_current_datetime(timezone=Asia/Tokyo)

    Foundry-->>VM: Run status: requires_action<br/>(tool_calls array)

    Note over VM,WFunc: Weather Tool Call
    VM->>Entra: Get token (EasyAuth scope)
    Entra-->>VM: Bearer token
    VM->>WFunc: GET /api/weather?city=Seattle<br/>Authorization: Bearer {token}<br/>(Resolves via Private DNS → PE)
    WFunc-->>VM: {"city":"Seattle","temp":"58°F",...}

    Note over VM,MCP: MCP Tool Call
    VM->>MCP: POST https://dtmcpk71j-app...io/mcp<br/>{"method":"tools/call",...}<br/>(VNet internal → 10.0.2.160)
    MCP-->>VM: {"datetime":"2026-04-17T12:00:00+09:00",...}

    Note over User,MCP: Phase 4: Submit Results
    VM->>Foundry: POST /threads/{id}/runs/{id}/submit_tool_outputs<br/>[weather_result, datetime_result]
    Foundry->>GPT: Generate natural language response
    GPT-->>Foundry: "It's 58°F in Seattle...<br/>The time in Tokyo is 12:00 PM JST..."
    Foundry-->>VM: Run status: completed<br/>+ assistant message

    Note over User,MCP: Phase 5: Display Result
    VM-->>User: Print formatted response
```

### 3b. Teams / M365 Flow (Agent Webapp)

```mermaid
sequenceDiagram
    participant User as User (Teams)
    participant Teams as Microsoft Teams
    participant Bot as Bot Framework<br/>Connector
    participant Webapp as Agent Webapp<br/>(aiohttp + Agents SDK)
    participant Entra as Microsoft Entra ID
    participant Foundry as AI Foundry API
    participant GPT as gpt-4.1-mini
    participant WFunc as Weather Function<br/>(EasyAuth + MI)
    participant MCP as DateTime MCP<br/>(VNet Internal)
    participant AI as App Insights

    Note over User,AI: Phase 1: Message Delivery
    User->>Teams: "What's the weather in Seattle<br/>and current time?"
    Teams->>Bot: Activity (message)
    Bot->>Webapp: POST /api/messages<br/>Authorization: Bearer {channel-token}
    Webapp->>Webapp: Agents SDK validates token<br/>Deserializes Activity

    Note over User,AI: Phase 2: Agent Processing
    Webapp->>Webapp: Send typing indicator
    Webapp->>Foundry: POST /threads + messages + runs<br/>(DefaultAzureCredential → MI token)

    Note over Webapp,MCP: Phase 3: Tool Execution (Webapp-Side)
    Foundry->>GPT: Analyze → select tools
    GPT-->>Foundry: requires_action:<br/>get_weather + get_current_datetime
    Foundry-->>Webapp: tool_calls array

    Note over Webapp,WFunc: Weather Tool Call
    Webapp->>Entra: MI token for EasyAuth audience
    Entra-->>Webapp: Bearer token (MI appId in allowedApplications)
    Webapp->>WFunc: GET /api/weather?city=Seattle<br/>Authorization: Bearer {mi-token}<br/>(VNet → Private Endpoint)
    WFunc-->>Webapp: Weather JSON

    Note over Webapp,MCP: MCP Tool Call
    Webapp->>MCP: POST /mcp<br/>(VNet internal DNS resolution)
    MCP-->>Webapp: DateTime JSON

    Note over User,AI: Phase 4: Submit & Reply
    Webapp->>Foundry: submit_tool_outputs
    Foundry->>GPT: Generate response
    GPT-->>Foundry: Natural language reply
    Foundry-->>Webapp: Completed + message

    Webapp->>Bot: Reply Activity<br/>(via context.send_activity)
    Bot->>Teams: Display reply
    Teams-->>User: "The current time in Pacific Time<br/>is 6:09 AM. The weather in Seattle<br/>is sunny, 48.7°F..."

    Note over User,AI: Telemetry (continuous)
    Webapp-->>AI: Request traces, spans, metrics
    WFunc-->>AI: Function execution telemetry
    MCP-->>AI: MCP call telemetry
```

## 4. Detailed Network Architecture

```mermaid
graph TB
    subgraph VNet["agent-vnet — 10.0.0.0/16 — eastus2"]
        subgraph S1["agent-subnet<br/>10.0.0.0/24<br/>Delegation: Microsoft.App/environments<br/>NSG: agent-vnet-agent-subnet-nsg-eastus2"]
            DataProxy["AI Services Data Proxy<br/>(Network Injection into VNet)"]
        end

        subgraph S2["pe-subnet<br/>10.0.1.0/24<br/>NSG: agent-vnet-pe-subnet-nsg-eastus2"]
            PE1["PE: aiservicesk71j<br/>→ cognitiveservices"]
            PE2["PE: aiservicesk71jst<br/>→ blob"]
            PE3["PE: aiservicesk71jcosmosdb<br/>→ documents"]
            PE4["PE: weatherk71j-func<br/>→ sites"]
            PE5["PE: toolqk71jst<br/>→ queue"]
            PE6["PE: weatherk71jstor<br/>→ file"]
        end

        subgraph S3["mcp-subnet<br/>10.0.2.0/24<br/>Delegation: Microsoft.App/environments<br/>NSG: agent-vnet-mcp-subnet-nsg-eastus2"]
            CAE["Container Apps Environment<br/>Internal Load Balancer<br/>Static IP: 10.0.2.160"]
            MCP["dtmcpk71j-app<br/>HTTPS:443 → 8080<br/>Streamable HTTP MCP"]
        end

        subgraph S4["func-integration-subnet<br/>10.0.3.0/24<br/>Delegation: Microsoft.Web/serverFarms<br/>NSG: agent-vnet-func-integration-subnet-nsg-eastus2"]
            FuncInt["Weather Function<br/>VNet Integration<br/>(Outbound traffic only)"]
        end

        subgraph S5["jumpbox-subnet<br/>10.0.4.0/24<br/>NSG (NIC): jumpbox-vm-nsg<br/>NSG (Subnet): agent-vnet-jumpbox-subnet-nsg-eastus2<br/>Both have: AllowSSH TCP/22 Priority 100"]
            JVM["jumpbox-vm<br/>Standard_B1s / Ubuntu 24.04<br/>Private: 10.0.4.4<br/>Public: 172.176.124.151"]
        end

        subgraph S6["agent-app-subnet<br/>10.0.6.0/23<br/>Delegation: Microsoft.App/environments<br/>NSG: agent-vnet-agent-app-subnet-nsg-eastus2"]
            AgentCAE["Container Apps Environment<br/>External (internet-facing)<br/>Public FQDN: *.wonderfulplant-f418865a.eastus2.azurecontainerapps.io"]
            AgentApp["agentappk71j-app<br/>aiohttp + Microsoft Agents SDK<br/>1 CPU / 2Gi / 1-5 replicas<br/>POST /api/messages + GET /healthz"]
        end
    end

    subgraph DNS["Private DNS Zones (All linked to agent-vnet)"]
        D1["privatelink.cognitiveservices.azure.com<br/>→ AI Services PE"]
        D2["privatelink.blob.core.windows.net<br/>→ Storage Blob PEs (×2)"]
        D3["privatelink.documents.azure.com<br/>→ Cosmos DB PE"]
        D4["privatelink.azurewebsites.net<br/>→ Weather Function PE"]
        D5["privatelink.queue.core.windows.net<br/>→ Queue Storage PEs (×2)"]
        D6["privatelink.file.core.windows.net<br/>→ File Storage PE"]
        D7["niceriver-877b9fd9.eastus2.azurecontainerapps.io<br/>A: * → 10.0.2.160<br/>A: @ → 10.0.2.160"]
    end

    subgraph Obs["Observability (not VNet-bound)"]
        AI["Application Insights<br/>hybrid-agent-k71j-appinsights"]
        LAW["Log Analytics Workspace<br/>hybrid-agent-k71j-law<br/>PerGB2018 / 30-day retention"]
    end

    PE1 -.-> D1
    PE2 -.-> D2
    PE3 -.-> D3
    PE4 -.-> D4
    PE5 -.-> D5
    PE6 -.-> D6
    CAE -.-> D7
    AgentApp -.->|"VNet DNS link resolves<br/>MCP internal FQDN"| D7

    MCP -.->|"Telemetry"| AI
    AgentApp -.->|"Telemetry"| AI
    FuncInt -.->|"Telemetry"| AI
    AI -.-> LAW

    style VNet fill:#d0ebff,stroke:#1971c2,stroke-width:3px
    style S1 fill:#d0bfff,stroke:#6741d9
    style S2 fill:#eebefa,stroke:#9c36b5
    style S3 fill:#b2f2bb,stroke:#2f9e44
    style S4 fill:#ffec99,stroke:#f08c00
    style S5 fill:#ffd8a8,stroke:#e8590c
    style S6 fill:#c3fae8,stroke:#087f5b
    style DNS fill:#d0bfff,stroke:#6741d9
    style Obs fill:#fff3bf,stroke:#e67700
```

---

## 5. Observability Architecture

```mermaid
graph LR
    subgraph Sources["Telemetry Sources"]
        AW["Agent Webapp<br/>logger: agent-webapp<br/>+ OTel spans for tool calls"]
        WF["Weather Function<br/>logger: weather-function"]
        MCP["MCP Server<br/>logger: datetime-mcp"]
    end

    subgraph SDK["Azure Monitor OpenTelemetry SDK"]
        CFG["configure_azure_monitor()<br/>connection_string=...<br/>enable_live_metrics=True"]
    end

    subgraph AppInsights["Application Insights<br/>hybrid-agent-k71j-appinsights"]
        LM["Live Metrics<br/>(real-time)"]
        TX["Transaction Search<br/>(distributed traces)"]
        MET["Metrics Explorer<br/>(agents.adapter.process.duration)"]
        FAIL["Failure Analysis<br/>(0 failed requests)"]
    end

    subgraph LAW["Log Analytics Workspace<br/>hybrid-agent-k71j-law"]
        KQL["KQL Queries"]
        RET["30-day retention"]
    end

    AW --> CFG
    WF --> CFG
    MCP --> CFG
    CFG --> AppInsights
    AppInsights --> LAW

    style Sources fill:#d0ebff,stroke:#1971c2
    style SDK fill:#b2f2bb,stroke:#2f9e44
    style AppInsights fill:#fff3bf,stroke:#e67700
    style LAW fill:#d0bfff,stroke:#6741d9
```

---

**Project Details:**
- **Region:** eastus2
- **Subscription:** ME-MngEnvMCAP687688-surep-1
- **Resource Group:** rg-hybrid-agent
- **Agent:** pce (`asst_fAVIpp16oVnfHaBuCo1BtvJ9`) — 6 function tools
- **Model:** gpt-4.1-mini (GlobalStandard, capacity 30)
- **Tool Type:** `function` (client-executed — not compatible with Agent Playground)
- **Two Access Patterns:**
  - **Jump VM:** Direct CLI via `foundry_agent.py` (SSH → VNet)
  - **M365 Teams:** Bot Framework Activities → Agent Webapp Container App → Foundry Agent
- **Observability:** Application Insights + Log Analytics (all 3 services instrumented)
- **Security:** Managed identity, EasyAuth + allowedApplications, Private Endpoints, no shared keys, no local auth
- **Terraform:** 10 modules, ~55+ resources, full state management with lifecycle ignores
