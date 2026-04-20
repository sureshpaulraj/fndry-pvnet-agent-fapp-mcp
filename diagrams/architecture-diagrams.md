# Hybrid VNet AI Agent — Architecture Diagrams

## 1. High-Level Architecture

```mermaid
graph TB
    subgraph Internet["Internet / Public"]
        User["User · SSH Client"]
        M365["M365 · Teams / Outlook"]
        EntraID["Entra ID · Token Issuance"]
        FoundryAPI["AI Foundry Agent API"]
        WeatherFQDN["Weather Function FQDN"]
        BotConnector["Bot Framework Connector"]
    end

    subgraph VNet["agent-vnet · 10.0.0.0/16"]
        subgraph AgentSubnet["agent-subnet · 10.0.0.0/24"]
            DataProxy["AI Services Data Proxy"]
        end

        subgraph PESubnet["pe-subnet · 10.0.1.0/24"]
            PE_AI["PE: AI Services"]
            PE_Blob["PE: Blob"]
            PE_Cosmos["PE: Cosmos DB"]
            PE_Func["PE: Weather Func"]
            PE_Queue["PE: Queue"]
            PE_File["PE: File"]
        end

        subgraph MCPSubnet["mcp-subnet · 10.0.2.0/24"]
            CAE["CAE Internal · 10.0.2.160"]
            MCPServer["DateTime MCP Server"]
        end

        subgraph FuncSubnet["func-integration · 10.0.3.0/24"]
            FuncVNet["Weather Func VNet Out"]
        end

        subgraph JumpSubnet["jumpbox-subnet · 10.0.4.0/24"]
            JumpVM["jumpbox-vm · Ubuntu 24.04"]
        end

        subgraph AgentAppSubnet["agent-app-subnet · 10.0.6.0/23"]
            AgentCAE["CAE External · internet-facing"]
            AgentWebapp["Agent Webapp · Agents SDK"]
        end
    end

    subgraph Services["Azure PaaS Services"]
        AISvc["AI Services · S0 · gpt-4.1-mini"]
        WeatherFunc["Weather Function · Flex FC1"]
        ACR["ACR: acrdtmcpk71j"]
        Storage1["Storage: AI data blob"]
        Storage2["Storage: blob+queue+file"]
        Storage3["Storage: tool queues"]
        CosmosDB["Cosmos DB · threads"]
    end

    subgraph Observability["Observability"]
        AppInsights["Application Insights"]
        LAW["Log Analytics Workspace"]
    end

    User -->|"SSH TCP/22"| JumpVM
    JumpVM -->|"HTTPS + Bearer"| FoundryAPI
    JumpVM -->|"Entra Token"| EntraID
    JumpVM -->|"EasyAuth Bearer"| WeatherFQDN
    JumpVM -->|"POST /mcp · VNet"| MCPServer

    M365 -->|"Bot Activities"| BotConnector
    BotConnector -->|"POST /api/messages"| AgentWebapp
    AgentWebapp -->|"Foundry API · MI"| FoundryAPI
    AgentWebapp -->|"MI Token · EasyAuth"| WeatherFQDN
    AgentWebapp -->|"POST /mcp · VNet DNS"| MCPServer
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
    AppInsights -.->|"Logs"| LAW

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
        VM["Jump VM · foundry_agent.py"]
        Teams["Teams / Outlook"]
    end

    subgraph M365Layer["M365 Integration"]
        BotConnector["Bot Framework Connector"]
        AgentWebapp["Agent Webapp · Agents SDK v0.9"]
    end

    subgraph AgentLayer["Agent Orchestration"]
        FoundryAgent["Foundry Agent 'pce'"]
        GPT["gpt-4.1-mini · cap=30"]
    end

    subgraph ToolLayer["Tool Execution · 6 Functions"]
        subgraph WeatherTools["Weather · Azure Function + EasyAuth"]
            T1["get_weather"]
            T2["get_forecast"]
            T3["get_weather_alerts"]
        end
        subgraph DateTimeTools["DateTime · MCP Server"]
            T4["get_current_datetime"]
            T5["convert_timezone"]
            T6["calculate_time_difference"]
        end
    end

    subgraph BackendLayer["Backend Services"]
        AISvc["AI Services · S0 · MI Only"]
        FuncApp["Weather Func · Flex FC1"]
        ContainerApp["MCP Server · Internal CAE"]
    end

    subgraph InfraLayer["Terraform · 10 Modules"]
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
        AppInsights["App Insights"]
        LAW["Log Analytics"]
        OTel["Azure Monitor OTel SDK"]
    end

    subgraph SecurityLayer["Security Controls"]
        Entra["Entra ID Auth"]
        EasyAuth["EasyAuth + allowedApps"]
        ManagedId["Managed Identity"]
        NSG["NSGs"]
        PE["Private Endpoints ×6"]
        DNS["Private DNS ×7"]
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
    subgraph VNet["agent-vnet · 10.0.0.0/16 · eastus2"]
        subgraph S1["agent-subnet · 10.0.0.0/24"]
            S1D["Delegated: App/environments"]
            DataProxy["AI Services Data Proxy"]
        end

        subgraph S2["pe-subnet · 10.0.1.0/24"]
            PE1["PE: AI Services"]
            PE2["PE: Blob Storage"]
            PE3["PE: Cosmos DB"]
            PE4["PE: Weather Function"]
            PE5["PE: Queue Storage"]
            PE6["PE: File Storage"]
        end

        subgraph S3["mcp-subnet · 10.0.2.0/24"]
            S3D["Delegated: App/environments"]
            CAE["CAE Internal LB · 10.0.2.160"]
            MCP["dtmcpk71j-app · MCP Server"]
        end

        subgraph S4["func-integration · 10.0.3.0/24"]
            S4D["Delegated: Web/serverFarms"]
            FuncInt["Weather Function VNet Out"]
        end

        subgraph S5["jumpbox-subnet · 10.0.4.0/24"]
            S5N["NSG: AllowSSH TCP/22"]
            JVM["jumpbox-vm · B1s · Ubuntu"]
            JVM2["10.0.4.4 / 172.176.124.151"]
        end

        subgraph S6["agent-app-subnet · 10.0.6.0/23"]
            S6D["Delegated: App/environments"]
            AgentCAE["CAE External · internet-facing"]
            AgentApp["agentappk71j-app"]
            AgentApp2["Agents SDK · 1-5 replicas"]
        end
    end

    subgraph DNS["Private DNS Zones"]
        D1["cognitiveservices → AI Services"]
        D2["blob → Storage ×2"]
        D3["documents → Cosmos DB"]
        D4["azurewebsites → Weather Func"]
        D5["queue → Queue Storage ×2"]
        D6["file → File Storage"]
        D7["CAE zone → 10.0.2.160"]
    end

    subgraph Obs["Observability"]
        AI["App Insights"]
        LAW["Log Analytics · 30d"]
    end

    PE1 -.-> D1
    PE2 -.-> D2
    PE3 -.-> D3
    PE4 -.-> D4
    PE5 -.-> D5
    PE6 -.-> D6
    CAE -.-> D7
    AgentApp -.->|"VNet DNS → MCP"| D7

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

> **Diagram 4 Legend — Subnet Details:**
> | Subnet | CIDR | Delegation | NSG |
> |--------|------|------------|-----|
> | agent-subnet | 10.0.0.0/24 | Microsoft.App/environments | agent-vnet-agent-subnet-nsg-eastus2 |
> | pe-subnet | 10.0.1.0/24 | — | agent-vnet-pe-subnet-nsg-eastus2 |
> | mcp-subnet | 10.0.2.0/24 | Microsoft.App/environments | agent-vnet-mcp-subnet-nsg-eastus2 |
> | func-integration | 10.0.3.0/24 | Microsoft.Web/serverFarms | agent-vnet-func-integration-subnet-nsg-eastus2 |
> | jumpbox-subnet | 10.0.4.0/24 | — | jumpbox-vm-nsg (NIC) + subnet NSG |
> | agent-app-subnet | 10.0.6.0/23 | Microsoft.App/environments | agent-vnet-agent-app-subnet-nsg-eastus2 |
>
> **Private DNS Zones (all linked to agent-vnet):**
> | Zone | Target |
> |------|--------|
> | privatelink.cognitiveservices.azure.com | AI Services PE |
> | privatelink.blob.core.windows.net | Storage Blob PEs (×2) |
> | privatelink.documents.azure.com | Cosmos DB PE |
> | privatelink.azurewebsites.net | Weather Function PE |
> | privatelink.queue.core.windows.net | Queue Storage PEs (×2) |
> | privatelink.file.core.windows.net | File Storage PE |
> | niceriver-877b9fd9.eastus2.azurecontainerapps.io | A: * → 10.0.2.160, A: @ → 10.0.2.160 |

---

## 5. Observability Architecture

```mermaid
graph LR
    subgraph Sources["Telemetry Sources"]
        AW["Agent Webapp"]
        WF["Weather Function"]
        MC["MCP Server"]
    end

    subgraph SDK["Azure Monitor OTel SDK"]
        CFG["configure_azure_monitor()"]
    end

    subgraph AI["Application Insights"]
        LM["Live Metrics"]
        TX["Transaction Search"]
        MET["Metrics Explorer"]
        FAIL["Failure Analysis"]
    end

    subgraph LAW["Log Analytics · 30d"]
        KQL["KQL Queries"]
    end

    AW --> CFG
    WF --> CFG
    MC --> CFG
    CFG --> AI
    AI --> LAW

    style Sources fill:#d0ebff,stroke:#1971c2
    style SDK fill:#b2f2bb,stroke:#2f9e44
    style AI fill:#fff3bf,stroke:#e67700
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
