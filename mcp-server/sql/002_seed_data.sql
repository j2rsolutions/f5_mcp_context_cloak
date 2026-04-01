-- Context Cloak: Sample Seed Data
-- All data is fictional. Do not use real PII.

BEGIN;

-- Clear existing data (idempotent re-runs)
TRUNCATE audit_log, financial_accounts, customers RESTART IDENTITY CASCADE;

-- Customers
INSERT INTO customers (full_name, ssn, date_of_birth, address, city, state, zip_code, phone, email) VALUES
('John Doe',       '078-05-1120', '1985-03-15', '742 Evergreen Terrace',  'Springfield', 'IL', '62704', '217-555-0142', 'john.doe@example.com'),
('Jane Smith',     '219-09-9999', '1990-07-22', '1600 Pennsylvania Ave',  'Washington',  'DC', '20500', '202-555-0198', 'jane.smith@example.com'),
('Carlos Rivera',  '323-45-6789', '1978-11-03', '350 Fifth Avenue',       'New York',    'NY', '10118', '212-555-0167', 'carlos.rivera@example.com'),
('Aisha Patel',    '456-78-9012', '1995-01-30', '1 Infinite Loop',        'Cupertino',   'CA', '95014', '408-555-0134', 'aisha.patel@example.com'),
('Robert Chen',    '567-89-0123', '1982-09-12', '2001 Odyssey Way',       'Houston',     'TX', '77058', '281-555-0156', 'robert.chen@example.com');

-- Financial accounts for John Doe (customer_id=1)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(1, '4532-1189-0042',      'checking',    45230.18, 'USD', '2010-06-01', 'active'),
(1, '4532-1189-0043',      'savings',    128750.00, 'USD', '2010-06-01', 'active'),
(1, '7891-0023-4567-8901', 'credit',      -3420.55, 'USD', '2015-03-15', 'active'),
(1, '4532-1189-0099',      'investment', 312500.00, 'USD', '2018-01-10', 'active');

-- Financial accounts for Jane Smith (customer_id=2)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(2, '5678-2234-0011',      'checking',    12340.67, 'USD', '2015-09-20', 'active'),
(2, '5678-2234-0012',      'savings',     67890.00, 'USD', '2015-09-20', 'active'),
(2, '8901-3345-6789-0123', 'credit',      -1250.30, 'USD', '2019-11-01', 'active');

-- Financial accounts for Carlos Rivera (customer_id=3)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(3, '6789-3345-0022',      'checking',    89120.45, 'USD', '2008-02-14', 'active'),
(3, '6789-3345-0023',      'savings',    245000.00, 'USD', '2008-02-14', 'active'),
(3, '6789-3345-0024',      'investment', 890000.00, 'USD', '2012-07-04', 'active');

-- Financial accounts for Aisha Patel (customer_id=4)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(4, '7890-4456-0033',      'checking',     8920.33, 'USD', '2020-01-15', 'active'),
(4, '7890-4456-0034',      'savings',     34500.00, 'USD', '2020-01-15', 'active');

-- Financial accounts for Robert Chen (customer_id=5)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(5, '8901-5567-0044',      'checking',    56780.92, 'USD', '2012-11-30', 'active'),
(5, '8901-5567-0045',      'savings',    189000.00, 'USD', '2012-11-30', 'active'),
(5, '9012-6678-7890-1234', 'credit',       -890.00, 'USD', '2020-05-01', 'active'),
(5, '8901-5567-0099',      'investment', 425000.00, 'USD', '2016-08-22', 'active');

COMMIT;
