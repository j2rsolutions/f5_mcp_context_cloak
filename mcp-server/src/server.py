"""Context Cloak MCP Server.

A simple MCP server that exposes customer data tools backed by Postgres.
Designed to run behind an F5 BIG-IP that handles session persistence
and PII anonymization.
"""

from mcp.server.fastmcp import FastMCP

from .config import config
from . import tools

mcp = FastMCP(
    "Context Cloak",
    description="Customer data tools for the Context Cloak privacy-preserving LLM POC",
)


@mcp.tool()
def get_customer_by_name(name: str) -> str:
    """Look up a customer record by full name.

    Returns the customer's profile including name, date of birth,
    address, phone, and email. Use get_customer_ssn separately
    to retrieve the SSN.

    Args:
        name: Full name of the customer (e.g., "John Doe")
    """
    return tools.get_customer_by_name(name)


@mcp.tool()
def get_customer_financial_summary(customer_name: str) -> str:
    """Get all financial accounts and balances for a customer.

    Returns account numbers, types, balances, currency, and status
    for every account belonging to the named customer.

    Args:
        customer_name: Full name of the customer (e.g., "John Doe")
    """
    return tools.get_customer_financial_summary(customer_name)


@mcp.tool()
def get_customer_ssn(customer_name: str) -> str:
    """Retrieve the SSN for a customer. This is a sensitive operation.

    Returns the Social Security Number for the named customer.
    Access to this tool should be restricted in production.

    Args:
        customer_name: Full name of the customer (e.g., "John Doe")
    """
    return tools.get_customer_ssn(customer_name)


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host=config.server_host, port=config.server_port)
