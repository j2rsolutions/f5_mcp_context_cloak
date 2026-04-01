"""MCP tool definitions for the Context Cloak server."""

import json
from decimal import Decimal

from . import db


class DecimalEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal):
            return str(o)
        return super().default(o)


def _format_json(data) -> str:
    return json.dumps(data, cls=DecimalEncoder, default=str, indent=2)


def get_customer_by_name(name: str) -> str:
    """Look up a customer record by full name.

    Returns the customer's full profile including name, date of birth,
    address, phone, and email. Does NOT return SSN — use get_customer_ssn
    for that (separate tool for access control).
    """
    customer = db.get_customer_by_name(name)
    if customer is None:
        return json.dumps({"error": f"No customer found with name '{name}'"})

    db.log_tool_call("get_customer_by_name", customer["id"], None, json.dumps({"name": name}))

    # Return everything except SSN (separate tool for that)
    result = {k: v for k, v in customer.items() if k != "ssn"}
    return _format_json(result)


def get_customer_financial_summary(customer_name: str) -> str:
    """Get all financial accounts and balances for a customer.

    Returns account numbers, types, balances, and status for all accounts
    belonging to the named customer.
    """
    customer = db.get_customer_by_name(customer_name)
    if customer is None:
        return json.dumps({"error": f"No customer found with name '{customer_name}'"})

    accounts = db.get_customer_financial_summary(customer["id"])
    db.log_tool_call(
        "get_customer_financial_summary",
        customer["id"],
        None,
        json.dumps({"customer_name": customer_name}),
    )

    return _format_json({
        "customer_name": customer["full_name"],
        "customer_id": customer["id"],
        "accounts": accounts,
    })


def get_customer_ssn(customer_name: str) -> str:
    """Retrieve the SSN for a customer. This is a sensitive operation.

    Returns the Social Security Number for the named customer.
    This tool exists separately from get_customer_by_name to allow
    fine-grained access control.
    """
    customer = db.get_customer_by_name(customer_name)
    if customer is None:
        return json.dumps({"error": f"No customer found with name '{customer_name}'"})

    ssn = db.get_customer_ssn(customer["id"])
    db.log_tool_call(
        "get_customer_ssn",
        customer["id"],
        None,
        json.dumps({"customer_name": customer_name}),
    )

    return _format_json({
        "customer_name": customer["full_name"],
        "ssn": ssn,
    })
