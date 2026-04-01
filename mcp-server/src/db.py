"""Database access layer for the Context Cloak MCP server."""

import psycopg
from psycopg.rows import dict_row

from .config import config


def get_connection() -> psycopg.Connection:
    return psycopg.connect(config.dsn, row_factory=dict_row)


def get_customer_by_name(name: str) -> dict | None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM customers WHERE LOWER(full_name) = LOWER(%s)",
                (name,),
            )
            return cur.fetchone()


def get_customer_financial_summary(customer_id: int) -> list[dict]:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    fa.account_number,
                    fa.account_type,
                    fa.balance,
                    fa.currency,
                    fa.opened_date,
                    fa.status
                FROM financial_accounts fa
                WHERE fa.customer_id = %s
                ORDER BY fa.account_type
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
