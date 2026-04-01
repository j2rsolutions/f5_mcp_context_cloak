# Test Prompts for Context Cloak

## Prompt 1: Basic Financial Report (via Open WebUI with MCP)

Use this in Open WebUI with MCP tools enabled. Open WebUI will call the MCP
tools, then compose a prompt with the returned data.

```
Generate a comprehensive financial report for John Doe. Include all account
balances, account types, and a summary of total assets and liabilities.
Format the output as a professional report.
```

Expected behavior:
1. Open WebUI calls `get_customer_by_name("John Doe")` via MCP
2. Open WebUI calls `get_customer_financial_summary("John Doe")` via MCP
3. Open WebUI calls `get_customer_ssn("John Doe")` via MCP
4. Open WebUI composes a prompt with all fetched data
5. BIG-IP anonymizes the prompt before it reaches vLLM
6. vLLM generates a report using placeholders
7. BIG-IP restores real values in the response


## Prompt 2: Multi-Customer Comparison

```
Compare the financial profiles of John Doe and Jane Smith. Show their
account types, balances, and calculate the net worth for each customer.
Present the comparison in a table format.
```


## Prompt 3: Direct Placeholder Test (bypass MCP, send directly)

Use this to test the anonymization iRule directly without MCP involvement.
Send via curl to the inference VS.

```json
{
  "model": "default",
  "messages": [
    {
      "role": "system",
      "content": "You are a financial analyst. Any value in <<>> brackets is a data token. Reproduce all tokens exactly as-is in your output."
    },
    {
      "role": "user",
      "content": "Write a brief financial summary for customer John Doe (SSN: 078-05-1120). Their checking account 4532-1189-0042 has a balance of $45,230.18 and their savings account 4532-1189-0043 has $128,750.00. Their credit card 7891-0023-4567-8901 shows a balance of -$3,420.55."
    }
  ]
}
```

After BIG-IP anonymization, the prompt reaching vLLM should look like:

```json
{
  "model": "default",
  "messages": [
    {
      "role": "system",
      "content": "You are a financial analyst. Any value in <<>> brackets is a data token. Reproduce all tokens exactly as-is in your output."
    },
    {
      "role": "user",
      "content": "Write a brief financial summary for customer <<NAME:a1b2c3:001>> (SSN: <<SSN:a1b2c3:002>>). Their checking account <<ACCT:a1b2c3:003>> has a balance of <<BAL:a1b2c3:004>> and their savings account <<ACCT:a1b2c3:005>> has <<BAL:a1b2c3:006>>. Their credit card <<ACCT:a1b2c3:007>> shows a balance of -<<BAL:a1b2c3:008>>."
    }
  ]
}
```


## Prompt 4: Sensitive Data Access Audit

```
List all the personal information you have for Carlos Rivera, including
SSN, date of birth, address, and contact details. Also show all account
numbers and current balances.
```

This tests that all PII types are anonymized:
- Name
- SSN
- Date of birth
- Address/city/state/zip
- Phone number
- Email address
- Account numbers
- Balances
