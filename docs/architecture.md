# Architecture

## Component Diagram

```mermaid
graph LR
    User([User]) --> OpenWebUI[Open WebUI]

    subgraph Trusted Zone
        OpenWebUI
        subgraph Kubernetes - RKE2
            MCP[MCP Server]
            PG[(Postgres)]
        end
    end

    subgraph BIG-IP TMOS v21
        MCP_VS[MCP Virtual Server<br/>HTTP + JSON + SSE profiles<br/>Session persistence iRule]
        INF_VS[Inference Virtual Server<br/>HTTP + JSON profile<br/>Anonymization iRule]
        SUBTABLE[(Subtable<br/>Token Mappings)]
        INF_VS --- SUBTABLE
    end

    subgraph Untrusted Zone
        vLLM[vLLM Inference]
    end

    OpenWebUI -->|MCP JSON-RPC 2.0| MCP_VS
    MCP_VS -->|Session-pinned| MCP
    MCP --> PG

    OpenWebUI -->|LLM prompt| INF_VS
    INF_VS -->|Anonymized prompt| vLLM
    vLLM -->|Response with placeholders| INF_VS
    INF_VS -->|Restored response| OpenWebUI
```

## Sequence Diagram — End-to-End Flow

```mermaid
sequenceDiagram
    participant U as User
    participant OW as Open WebUI
    participant BM as BIG-IP MCP VS
    participant MCP as MCP Server
    participant PG as Postgres
    participant BI as BIG-IP Inference VS
    participant ST as BIG-IP Subtable
    participant LLM as vLLM

    U->>OW: "Generate a financial report for John Doe"

    Note over OW: Open WebUI decides to call MCP tools

    rect rgb(230, 245, 255)
        Note over OW,PG: MCP Tool Invocation (JSON-RPC 2.0)
        OW->>BM: POST /mcp (initialize)
        BM->>MCP: Forward (load-balanced)
        MCP-->>BM: Response + Mcp-Session-Id: abc123
        BM-->>OW: Mcp-Session-Id: pool1,10.0.1.5:8080,abc123

        OW->>BM: POST /mcp (tools/call: get_customer_by_name)<br/>Mcp-Session-Id: pool1,10.0.1.5:8080,abc123
        BM->>BM: Parse header, pin to pool1 member 10.0.1.5:8080
        BM->>MCP: POST /mcp (tools/call)<br/>Mcp-Session-Id: abc123
        MCP->>PG: SELECT * FROM customers WHERE name = 'John Doe'
        PG-->>MCP: {name, ssn, dob, ...}
        MCP-->>BM: Tool result with customer data
        BM-->>OW: Tool result (passthrough)

        OW->>BM: POST /mcp (tools/call: get_customer_financial_summary)
        BM->>MCP: Forward (same member)
        MCP->>PG: SELECT accounts, balances
        PG-->>MCP: {accounts, balances}
        MCP-->>BM: Financial summary
        BM-->>OW: Financial summary
    end

    Note over OW: Compose prompt with MCP-fetched data

    rect rgb(255, 235, 235)
        Note over OW,LLM: Inference with Anonymization
        OW->>BI: POST /v1/chat/completions<br/>{prompt contains SSN, accounts, balances}
        BI->>BI: Scan for PII patterns
        BI->>ST: Store mappings:<br/><<SSN:sid1:001>> → 078-05-1120<br/><<ACCT:sid1:002>> → 4532-1189-0042<br/><<NAME:sid1:003>> → John Doe
        BI->>LLM: POST /v1/chat/completions<br/>{prompt with <<SSN:sid1:001>>, <<ACCT:sid1:002>>, etc.}

        LLM-->>BI: Response using <<SSN:sid1:001>> etc.
        BI->>ST: Lookup mappings for sid1
        ST-->>BI: Original values
        BI->>BI: Replace placeholders with originals
        BI-->>OW: Response with real data restored
    end

    OW-->>U: "Here is the financial report for John Doe..."
```

## Network Topology

```mermaid
graph TB
    subgraph Client VLAN
        OW[Open WebUI<br/>10.0.10.x]
    end

    subgraph BIG-IP
        MCP_VIP["MCP VIP<br/>10.0.10.100:443"]
        INF_VIP["Inference VIP<br/>10.0.10.101:443"]
    end

    subgraph Server VLAN - Kubernetes
        MCP1[MCP Server Pod 1<br/>10.0.20.x:8080]
        MCP2[MCP Server Pod 2<br/>10.0.20.x:8080]
        PG[Postgres<br/>10.0.20.x:5432]
    end

    subgraph Inference VLAN
        VLLM[vLLM<br/>10.0.30.x:8000]
    end

    OW --> MCP_VIP
    OW --> INF_VIP
    MCP_VIP --> MCP1
    MCP_VIP --> MCP2
    MCP1 --> PG
    MCP2 --> PG
    INF_VIP --> VLLM
```

## AWS Deployment (BYOL)

When deploying BIG-IP on AWS using `terraform/aws-infra/`, the network topology maps to:

```mermaid
graph TB
    subgraph AWS us-east-1
        subgraph "VPC 10.0.0.0/16"
            subgraph "Management Subnet 10.0.0.0/24"
                MGMT_ENI["eth0 — Management<br/>10.0.0.200<br/>EIP: public"]
            end
            subgraph "External Subnet 10.0.1.0/24"
                EXT_ENI["eth1 — External<br/>Self: 10.0.1.200 (EIP)<br/>VIP: 10.0.1.100 (EIP) → MCP VS<br/>VIP: 10.0.1.101 (EIP) → Inference VS"]
            end
            subgraph "Internal Subnet 10.0.2.0/24"
                INT_ENI["eth2 — Internal<br/>10.0.2.200<br/>→ Pool members"]
            end
        end
        BIGIP["BIG-IP VE (m5.xlarge)<br/>BYOL Licensed<br/>3-NIC"]
        BIGIP --- MGMT_ENI
        BIGIP --- EXT_ENI
        BIGIP --- INT_ENI

        IGW[Internet Gateway]
        IGW --- EXT_ENI
        IGW --- MGMT_ENI
    end

    Admin([Admin]) -->|SSH/HTTPS| MGMT_ENI
    Client([Open WebUI]) -->|VIP EIPs| EXT_ENI
    INT_ENI -->|Pool traffic| K8s[Kubernetes Cluster]
    INT_ENI -->|Pool traffic| vLLM[vLLM Endpoint]
```

### Deployment workflow

1. `terraform/aws-infra/` creates the VPC, subnets, security groups, ENIs, EIPs, IAM role, Secrets Manager secret, and BIG-IP EC2 instance
2. BIG-IP boots with `f5-bigip-runtime-init` user_data, which installs DO and AS3, then applies Declarative Onboarding (BYOL license, VLANs, self IPs, provisioning)
3. After onboarding completes (~10 min), `terraform/bigip/` configures application objects (virtual servers, pools, iRules) using the management EIP

### Key resources

| Resource | Purpose |
|---|---|
| VPC + 3 subnets | Isolated network for mgmt, external, internal |
| 3 ENIs | One per BIG-IP interface with appropriate security groups |
| 4 EIPs | Management, external self, MCP VIP, Inference VIP |
| IAM role + policy | Allows BIG-IP to read admin password from Secrets Manager |
| Secrets Manager | Stores admin password securely |

## Trust Boundaries

| Zone | Components | Sees PII? |
|---|---|---|
| Client | User, Open WebUI | Yes |
| MCP (Trusted) | BIG-IP MCP VS, MCP Server, Postgres | Yes |
| Inference (Untrusted) | vLLM | **No** — only placeholders |
| Control Plane | BIG-IP (both VS + subtable) | Yes (enforcement point) |
