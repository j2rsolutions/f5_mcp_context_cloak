"""MCP tool definitions for the Context Cloak server."""

import json
import re
from decimal import Decimal

from . import db


class DecimalEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal):
            return str(o)
        return super().default(o)


def _format_json(data) -> str:
    return json.dumps(data, cls=DecimalEncoder, default=str, indent=2)


def _resolve_customer(query: str) -> dict | None:
    """Smart customer lookup -- tries SSN, account number, then name."""
    query = query.strip()
    if re.match(r"^\d{3}-\d{2}-\d{4}$", query):
        return db.get_customer_by_ssn(query)
    if re.match(r"^\d{4}-\d{4}-\d{4}", query):
        return db.get_customer_by_account_number(query)
    return db.get_customer_by_name(query)


def find_customer(query: str) -> str:
    customer = _resolve_customer(query)
    if customer is None:
        return json.dumps({"error": f"No customer found for '{query}'"})
    db.log_tool_call("find_customer", customer["id"], None, json.dumps({"query": query}))
    result = {k: v for k, v in customer.items() if k != "ssn"}
    return _format_json(result)


def get_customer_ssn(query: str) -> str:
    customer = _resolve_customer(query)
    if customer is None:
        return json.dumps({"error": f"No customer found for '{query}'"})
    ssn = db.get_customer_ssn(customer["id"])
    db.log_tool_call("get_customer_ssn", customer["id"], None, json.dumps({"query": query}))
    return _format_json({"customer_name": customer["full_name"], "ssn": ssn})


def get_accounts(query: str) -> str:
    customer = _resolve_customer(query)
    if customer is None:
        return json.dumps({"error": f"No customer found for '{query}'"})
    accounts = db.get_accounts_for_customer(customer["id"])
    db.log_tool_call("get_accounts", customer["id"], None, json.dumps({"query": query}))
    return _format_json({
        "customer_name": customer["full_name"],
        "customer_id": customer["id"],
        "accounts": accounts,
    })


def get_transactions(account_number: str, days: int = 30) -> str:
    account = db.get_account_by_number(account_number)
    if account is None:
        return json.dumps({"error": f"No account found with number '{account_number}'"})
    txns = db.get_transactions(account_number, days)
    db.log_tool_call("get_transactions", None, None,
                     json.dumps({"account_number": account_number, "days": days}))
    credits = sum(t["amount"] for t in txns if t["amount"] > 0)
    debits = sum(t["amount"] for t in txns if t["amount"] < 0)
    return _format_json({
        "account_number": account["account_number"],
        "account_type": account["account_type"],
        "customer_name": account["customer_name"],
        "current_balance": account["balance"],
        "period_days": days,
        "summary": {
            "total_credits": credits,
            "total_debits": debits,
            "net": credits + debits,
            "transaction_count": len(txns),
        },
        "transactions": txns,
    })
