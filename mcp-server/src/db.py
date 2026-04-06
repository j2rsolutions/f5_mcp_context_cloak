"""Database access layer for the Context Cloak MCP server."""

import psycopg
from psycopg.rows import dict_row

from .config import config


def get_connection() -> psycopg.Connection:
    return psycopg.connect(config.dsn, row_factory=dict_row)


# -----------------------------------------------------------------
# Customer lookups
# -----------------------------------------------------------------

def get_customer_by_name(name: str) -> dict | None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM customers WHERE LOWER(full_name) = LOWER(%s)",
                (name,),
            )
            return cur.fetchone()


def get_customer_by_ssn(ssn: str) -> dict | None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM customers WHERE ssn = %s",
                (ssn,),
            )
            return cur.fetchone()


def get_customer_by_account_number(account_number: str) -> dict | None:
    """Find the customer who owns a given account number."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT c.*
                FROM customers c
                JOIN financial_accounts fa ON fa.customer_id = c.id
                WHERE fa.account_number = %s
                LIMIT 1
                """,
                (account_number,),
            )
            return cur.fetchone()


# -----------------------------------------------------------------
# Account queries
# -----------------------------------------------------------------

def get_accounts_for_customer(customer_id: int) -> list[dict]:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT account_number, account_type, balance, currency,
                       opened_date, status
                FROM financial_accounts
                WHERE customer_id = %s
                ORDER BY account_type
                """,
                (customer_id,),
            )
            return cur.fetchall()


def get_customer_ssn(customer_id: int) -> str | None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT ssn FROM customers WHERE id = %s",
                (customer_id,),
            )
            row = cur.fetchone()
            return row["ssn"] if row else None


# -----------------------------------------------------------------
# Transaction queries
# -----------------------------------------------------------------

def get_transactions(account_number: str, days: int = 30) -> list[dict]:
    """Get recent transactions for an account, newest first."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT t.transaction_date, t.amount, t.description,
                       t.category, t.merchant, t.reference_number
                FROM transactions t
                JOIN financial_accounts fa ON fa.id = t.account_id
                WHERE fa.account_number = %s
                  AND t.transaction_date >= CURRENT_DATE - %s
                ORDER BY t.transaction_date DESC, t.id DESC
                """,
                (account_number, days),
            )
            return cur.fetchall()


def get_account_by_number(account_number: str) -> dict | None:
    """Look up a single account by its number, including the owner's name."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT fa.account_number, fa.account_type, fa.balance,
                       fa.currency, fa.opened_date, fa.status,
                       c.full_name AS customer_name
                FROM financial_accounts fa
                JOIN customers c ON c.id = fa.customer_id
                WHERE fa.account_number = %s
                """,
                (account_number,),
            )
            return cur.fetchone()


# -----------------------------------------------------------------
# Audit
# -----------------------------------------------------------------

def log_tool_call(
    tool_name: str,
    customer_id: int | None,
    request_id: str | None,
    parameters: str | None,
) -> None:
    """Record a tool invocation for audit purposes."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO audit_log (tool_name, customer_id, request_id, parameters)
                VALUES (%s, %s, %s, %s)
                """,
                (tool_name, customer_id, request_id, parameters),
            )
            conn.commit()
