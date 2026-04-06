"""Context Cloak MCP Server.

A simple MCP server that exposes customer and financial data tools
backed by Postgres.  Designed to run behind an F5 BIG-IP that handles
session persistence and PII cloaking.
"""

from mcp.server.fastmcp import FastMCP

from .config import config
from . import tools

mcp = FastMCP(
    "Context Cloak",
    host=config.server_host,
    port=config.server_port,
)


@mcp.tool()
def find_customer(query: str) -> str:
    """Find a customer by name, SSN, or account number.

    Returns the customer profile including name, date of birth,
    address, phone, and email.  SSN is NOT included -- use
    get_customer_ssn for that.

    Args:
        query: Customer name (e.g. "John Doe"), SSN (e.g. "078-05-1120"),
               or account number (e.g. "4532-1189-0042")
    """
    return tools.find_customer(query)


@mcp.tool()
def get_customer_ssn(query: str) -> str:
    """Retrieve the SSN for a customer.  This is a sensitive operation.

    Args:
        query: Customer name, SSN, or account number to identify the customer
    """
    return tools.get_customer_ssn(query)


@mcp.tool()
def get_accounts(query: str) -> str:
    """Get all financial accounts and balances for a customer.

    Returns account numbers, types, balances, currency, and status
    for every account belonging to the identified customer.

    Args:
        query: Customer name, SSN, or account number to identify the customer
    """
    return tools.get_accounts(query)


@mcp.tool()
def get_transactions(account_number: str, days: int = 30) -> str:
    """Get recent transaction history for a specific account.

    Returns transactions sorted newest-first, with amount, description,
    category, merchant, and a summary of total credits/debits.

    Args:
        account_number: The account number (e.g. "4532-1189-0042")
        days: Number of days of history to retrieve (default: 30)
    """
    return tools.get_transactions(account_number, days)


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
