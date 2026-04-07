# Demo Evidence: Substitute Mode in Action

This document captures real output from the Context Cloak proof-of-concept demonstrating how PII is substituted before reaching the LLM and restored on return.

## What the LLM Received (vLLM Logs)

The analyst asked: *"What accounts are associated to John Doe?"*

After the BIG-IP cloaked the request, **this is what Qwen 14B actually saw** (captured from vLLM server logs):

```json
{
  "customer_name": "Maria Garcia",
  "customer_id": 1,
  "accounts": [
    {
      "account_number": "7865-4412-3375",
      "account_type": "checking",
      "balance": "45230.18",
      "currency": "USD",
      "opened_date": "2010-06-01",
      "status": "active"
    },
    {
      "account_number": "7865-4412-3322",
      "account_type": "investment",
      "balance": "312500.00",
      "currency": "USD",
      "opened_date": "2018-01-10",
      "status": "active"
    },
    {
      "account_number": "7865-4412-3376",
      "account_type": "savings",
      "balance": "128750.00",
      "currency": "USD",
      "opened_date": "2010-06-01",
      "status": "active"
    }
  ]
}
```

The LLM prompt asked: *"what accounts are associated to Maria Garcia"*

**The LLM never saw "John Doe" or any real account numbers.**

## What the User Received (Open WebUI)

After the BIG-IP de-cloaked the response, **this is what the analyst saw**:

> The accounts associated with **John Doe** are as follows:
>
> **Checking Account:**
> - Account Number: **4532-1189-0042**
> - Balance: $45,230.18 USD
> - Opened Date: June 1, 2010
> - Status: Active
>
> **Investment Account:**
> - Account Number: **4532-1189-0099**
> - Balance: $312,500.00 USD
> - Opened Date: January 10, 2018
> - Status: Active
>
> **Savings Account:**
> - Account Number: **4532-1189-0043**
> - Balance: $128,750.00 USD
> - Opened Date: June 1, 2010
> - Status: Active

## Substitution Map

| Field | Real Value (user sees) | Fake Value (LLM sees) | Method |
|---|---|---|---|
| Customer Name | John Doe | Maria Garcia | Name pool hash |
| Checking Account | 4532-1189-0042 | 7865-4412-3375 | Digit shift +3 |
| Investment Account | 4532-1189-0099 | 7865-4412-3322 | Digit shift +3 |
| Savings Account | 4532-1189-0043 | 7865-4412-3376 | Digit shift +3 |

Note: Dollar amounts ($45,230.18, $312,500.00, $128,750.00) are **not cloaked** -- they are not PII and pass through unchanged.

## BIG-IP Cloaking Logs

```
CloakTable: customer_name (substitute) (session=32.192.169.232)
CloakTable: account_number (substitute) (session=32.192.169.232)
CloakTable: scan complete (session=32.192.169.232)
Cloak: request cloaked (4 values, session=32.192.169.232)
Decloak: response de-cloaked (4 values, session=32.192.169.232)
```

---

# Demo Evidence: Tokenize Mode in Action

## What the LLM Received (vLLM Logs)

The analyst asked: *"Show me the SSN number for Jane Smith. Just display the number."*

After the BIG-IP cloaked the request with **mixed modes** (substitute for name, tokenize for SSN), **this is what Qwen 14B actually saw**:

```json
{
  "customer_name": "Maria Thompson",
  "ssn": "<<SSN:32.192.169.232:001>>"
}
```

The LLM saw a fake name ("Maria Thompson") and a tokenized SSN placeholder. The BIG-IP also injected a guidance prompt instructing the LLM to reproduce the `<<SSN:...>>` token exactly.

## What the User Received (Open WebUI)

> The SSN given is **219-09-9999** [1].

The BIG-IP de-cloaked:
- `Maria Thompson` → `Jane Smith`
- `<<SSN:32.192.169.232:001>>` → `219-09-9999`

## Substitution + Tokenization Map (Mixed Mode)

| Field | Real Value (user sees) | Cloaked Value (LLM sees) | Mode |
|---|---|---|---|
| Customer Name | Jane Smith | Maria Thompson | **Substitute** (name pool) |
| SSN | 219-09-9999 | `<<SSN:32.192.169.232:001>>` | **Tokenize** |

## Key Insight: Mixed Modes Per Field

Both modes operated **in the same request** on the same customer record. The name was substituted with a realistic fake (for natural LLM reasoning), while the SSN was tokenized with a structured placeholder (for guardrails detection). The BIG-IP data group configuration drives this per-field:

```
full_name       → substitute:name
ssn             → tokenize:SSN
account_number  → substitute:digit_shift:3
```

---

---

# Demo Evidence: Full Tokenize Mode — All Fields

## What the LLM Received (vLLM Logs)

The analyst asked: *"Show me the SSN and account information for Carlos Rivera. Display all the numbers."*

With **all fields set to tokenize**, the BIG-IP replaced every PII value with `<<TYPE:SESSION:SEQ>>` placeholders. **This is what Qwen 14B actually saw**:

```json
{
  "id": 3,
  "full_name": "<<name:32.192.169.232:001>>",
  "date_of_birth": "1978-11-03",
  "phone": "<<phone:32.192.169.232:002>>",
  "email": "<<email:32.192.169.232:001>>",
}
```

```json
{
  "customer_name": "<<name:32.192.169.232:001>>",
  "ssn": "<<SSN:32.192.169.232:002>>"
}
```

```json
{
  "customer_name": "<<name:32.192.169.232:001>>",
  "accounts": [
    {"account_number": "<<digit_shift:32.192.169.232:002>>", "account_type": "checking", "balance": "89120.45"},
    {"account_number": "<<digit_shift:32.192.169.232:003>>", "account_type": "investment", "balance": "890000.00"},
    {"account_number": "<<digit_shift:32.192.169.232:004>>", "account_type": "savings", "balance": "245000.00"}
  ]
}
```

Even the user's prompt was tokenized: *"show me the SSN and account information for <<name:32.192.169.232:001>>. Display all the numbers."*

**The LLM never saw "Carlos Rivera", his SSN, phone, email, or any real account numbers.**

## What the User Received (Open WebUI)

> The Social Security Number (SSN) and account details for **Carlos Rivera** are as follows:
>
> **Social Security Number (SSN):**
> **323-45-6789**
>
> **Account Information:**
>
> **Checking Account:**
> - Account Number: **6789-3345-0022**
> - Balance: $89,120.45
>
> **Investment Account:**
> - Account Number: **6789-3345-0024**
> - Balance: $890,000.00
>
> **Savings Account:**
> - Account Number: **6789-3345-0023**
> - Balance: $245,000.00
>
> All numerical data has been displayed as requested. [1][2][3]
>
> *Please note that the actual numerical values for the SSN and account numbers are masked due to privacy concerns.*

## The Punchline

Qwen's last line: *"Please note that the actual numerical values for the SSN and account numbers are masked due to privacy concerns."*

**The LLM genuinely believes it showed the user masked/placeholder data.** It has no idea that the BIG-IP de-cloaked every token back to the real values before the user saw them. The LLM is apologizing for showing "masked" data — while the user sees the full, real, unmasked report.

This is Context Cloak working exactly as designed.

## Full Tokenization Map

| Field | Real Value (user sees) | Token (LLM sees) | Mode |
|---|---|---|---|
| Name | Carlos Rivera | `<<name:32.192.169.232:001>>` | Tokenize |
| SSN | 323-45-6789 | `<<SSN:32.192.169.232:002>>` | Tokenize |
| Phone | 212-555-0167 | `<<phone:32.192.169.232:002>>` | Tokenize |
| Email | carlos.rivera@example.com | `<<email:32.192.169.232:001>>` | Tokenize |
| Checking Acct | 6789-3345-0022 | `<<digit_shift:32.192.169.232:002>>` | Tokenize |
| Investment Acct | 6789-3345-0024 | `<<digit_shift:32.192.169.232:003>>` | Tokenize |
| Savings Acct | 6789-3345-0023 | `<<digit_shift:32.192.169.232:004>>` | Tokenize |

---

## Key Takeaway

The LLM produced a perfect financial report. It formatted account numbers, organized by account type, and presented balances clearly. Its behavior was identical to processing real data -- because the substituted data **looked real** (substitute mode) or because the guidance prompt told it to treat tokens as real values (tokenize mode). The LLM had no idea the data wasn't real.
