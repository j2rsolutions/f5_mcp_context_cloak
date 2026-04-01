-- Context Cloak: Database Schema
-- Run this before seed data.

BEGIN;

CREATE TABLE IF NOT EXISTS customers (
    id              SERIAL PRIMARY KEY,
    full_name       VARCHAR(200) NOT NULL,
    ssn             VARCHAR(11) NOT NULL,       -- ###-##-####
    date_of_birth   DATE NOT NULL,
    address         TEXT,
    city            VARCHAR(100),
    state           VARCHAR(2),
    zip_code        VARCHAR(10),
    phone           VARCHAR(20),
    email           VARCHAR(200),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_customers_name ON customers (LOWER(full_name));

CREATE TABLE IF NOT EXISTS financial_accounts (
    id              SERIAL PRIMARY KEY,
    customer_id     INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    account_number  VARCHAR(30) NOT NULL,
    account_type    VARCHAR(20) NOT NULL,       -- checking, savings, credit, investment
    balance         NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    currency        VARCHAR(3) NOT NULL DEFAULT 'USD',
    opened_date     DATE NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'active',  -- active, closed, frozen
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_accounts_customer ON financial_accounts (customer_id);

CREATE TABLE IF NOT EXISTS audit_log (
    id              SERIAL PRIMARY KEY,
    tool_name       VARCHAR(100) NOT NULL,
    customer_id     INTEGER REFERENCES customers(id),
    request_id      VARCHAR(100),
    parameters      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log (created_at);

COMMIT;
