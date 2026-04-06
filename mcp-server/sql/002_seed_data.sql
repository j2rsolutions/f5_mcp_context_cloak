-- Context Cloak: Sample Seed Data
-- All data is fictional. Do not use real PII.

BEGIN;

-- Clear existing data (idempotent re-runs)
TRUNCATE audit_log, transactions, financial_accounts, customers RESTART IDENTITY CASCADE;

-- =====================================================================
-- Customers
-- =====================================================================
INSERT INTO customers (full_name, ssn, date_of_birth, address, city, state, zip_code, phone, email) VALUES
('John Doe',       '078-05-1120', '1985-03-15', '742 Evergreen Terrace',  'Springfield', 'IL', '62704', '217-555-0142', 'john.doe@example.com'),
('Jane Smith',     '219-09-9999', '1990-07-22', '1600 Pennsylvania Ave',  'Washington',  'DC', '20500', '202-555-0198', 'jane.smith@example.com'),
('Carlos Rivera',  '323-45-6789', '1978-11-03', '350 Fifth Avenue',       'New York',    'NY', '10118', '212-555-0167', 'carlos.rivera@example.com'),
('Aisha Patel',    '456-78-9012', '1995-01-30', '1 Infinite Loop',        'Cupertino',   'CA', '95014', '408-555-0134', 'aisha.patel@example.com'),
('Robert Chen',    '567-89-0123', '1982-09-12', '2001 Odyssey Way',       'Houston',     'TX', '77058', '281-555-0156', 'robert.chen@example.com');

-- =====================================================================
-- Financial Accounts
-- =====================================================================
-- John Doe (customer_id=1)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(1, '4532-1189-0042', 'checking',    45230.18, 'USD', '2010-06-01', 'active'),
(1, '4532-1189-0043', 'savings',    128750.00, 'USD', '2010-06-01', 'active'),
(1, '4532-1189-0099', 'investment', 312500.00, 'USD', '2018-01-10', 'active');

-- Jane Smith (customer_id=2)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(2, '5678-2234-0011', 'checking',  12340.67, 'USD', '2015-09-20', 'active'),
(2, '5678-2234-0012', 'savings',   67890.00, 'USD', '2015-09-20', 'active');

-- Carlos Rivera (customer_id=3)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(3, '6789-3345-0022', 'checking',   89120.45, 'USD', '2008-02-14', 'active'),
(3, '6789-3345-0023', 'savings',   245000.00, 'USD', '2008-02-14', 'active'),
(3, '6789-3345-0024', 'investment', 890000.00, 'USD', '2012-07-04', 'active');

-- Aisha Patel (customer_id=4)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(4, '7890-4456-0033', 'checking',  8920.33, 'USD', '2020-01-15', 'active'),
(4, '7890-4456-0034', 'savings',  34500.00, 'USD', '2020-01-15', 'active');

-- Robert Chen (customer_id=5)
INSERT INTO financial_accounts (customer_id, account_number, account_type, balance, currency, opened_date, status) VALUES
(5, '8901-5567-0044', 'checking',   56780.92, 'USD', '2012-11-30', 'active'),
(5, '8901-5567-0045', 'savings',   189000.00, 'USD', '2012-11-30', 'active'),
(5, '8901-5567-0099', 'investment', 425000.00, 'USD', '2016-08-22', 'active');

-- =====================================================================
-- Transactions (last 30 days, relative to CURRENT_DATE)
-- =====================================================================

-- John Doe — checking (account_id=1)
INSERT INTO transactions (account_id, transaction_date, amount, description, category, merchant, reference_number) VALUES
(1, CURRENT_DATE - 1,  -67.43,   'Weekly grocery run',              'groceries',    'Whole Foods Market',       'TXN-JD-001'),
(1, CURRENT_DATE - 2,  -14.50,   'Morning coffee and pastry',       'dining',       'Starbucks #1142',          'TXN-JD-002'),
(1, CURRENT_DATE - 3,  3200.00,  'Bi-weekly salary deposit',        'income',       'Acme Corp Payroll',        'TXN-JD-003'),
(1, CURRENT_DATE - 4,  -189.99,  'Electric and gas bill',           'utilities',    'ComEd Illinois',           'TXN-JD-004'),
(1, CURRENT_DATE - 5,  -52.30,   'Gas station fill-up',             'transportation','Shell Station #0887',     'TXN-JD-005'),
(1, CURRENT_DATE - 6,  -127.84,  'Online electronics purchase',     'shopping',     'Amazon.com',               'TXN-JD-006'),
(1, CURRENT_DATE - 8,  -43.20,   'Family dinner',                   'dining',       'Olive Garden',             'TXN-JD-007'),
(1, CURRENT_DATE - 10, -95.00,   'Monthly gym membership',          'health',       'Planet Fitness',           'TXN-JD-008'),
(1, CURRENT_DATE - 12, -112.47,  'Grocery shopping',                'groceries',    'Trader Joes',              'TXN-JD-009'),
(1, CURRENT_DATE - 14, -200.00,  'ATM cash withdrawal',             'cash',         'ATM - Chase Bank',         'TXN-JD-010'),
(1, CURRENT_DATE - 15, -78.90,   'Internet bill',                   'utilities',    'Comcast Xfinity',          'TXN-JD-011'),
(1, CURRENT_DATE - 17, 3200.00,  'Bi-weekly salary deposit',        'income',       'Acme Corp Payroll',        'TXN-JD-012'),
(1, CURRENT_DATE - 18, -34.99,   'Streaming subscriptions',         'entertainment','Netflix + Spotify',        'TXN-JD-013'),
(1, CURRENT_DATE - 20, -156.30,  'Grocery and household items',     'groceries',    'Target',                   'TXN-JD-014'),
(1, CURRENT_DATE - 22, -48.75,   'Lunch meeting',                   'dining',       'Chipotle Mexican Grill',   'TXN-JD-015'),
(1, CURRENT_DATE - 24, -55.00,   'Gas station fill-up',             'transportation','BP Station #2241',        'TXN-JD-016'),
(1, CURRENT_DATE - 25, -1500.00, 'Transfer to savings',             'transfer',     'Internal Transfer',        'TXN-JD-017'),
(1, CURRENT_DATE - 27, -89.99,   'New running shoes',               'shopping',     'Nike.com',                 'TXN-JD-018'),
(1, CURRENT_DATE - 28, -22.50,   'Breakfast takeout',               'dining',       'Panera Bread',             'TXN-JD-019'),
(1, CURRENT_DATE - 30, -145.00,  'Car insurance monthly premium',   'insurance',    'State Farm Insurance',     'TXN-JD-020');

-- John Doe — savings (account_id=2)
INSERT INTO transactions (account_id, transaction_date, amount, description, category, merchant, reference_number) VALUES
(2, CURRENT_DATE - 25, 1500.00,  'Transfer from checking',          'transfer',     'Internal Transfer',        'TXN-JD-S01'),
(2, CURRENT_DATE - 3,  12.50,    'Monthly interest payment',        'interest',     'Bank Interest',            'TXN-JD-S02');

-- Jane Smith — checking (account_id=4)
INSERT INTO transactions (account_id, transaction_date, amount, description, category, merchant, reference_number) VALUES
(4, CURRENT_DATE - 1,  -32.15,   'Lunch delivery',                  'dining',       'DoorDash',                 'TXN-JS-001'),
(4, CURRENT_DATE - 2,  -245.00,  'Monthly rent utilities share',    'utilities',    'Washington Gas',           'TXN-JS-002'),
(4, CURRENT_DATE - 3,  4500.00,  'Monthly salary deposit',          'income',       'Federal Gov Payroll',      'TXN-JS-003'),
(4, CURRENT_DATE - 5,  -89.99,   'New dress for event',             'shopping',     'Nordstrom',                'TXN-JS-004'),
(4, CURRENT_DATE - 7,  -15.00,   'Metro card reload',               'transportation','WMATA SmarTrip',          'TXN-JS-005'),
(4, CURRENT_DATE - 8,  -67.80,   'Grocery shopping',                'groceries',    'Harris Teeter',            'TXN-JS-006'),
(4, CURRENT_DATE - 10, -42.00,   'Happy hour with friends',         'dining',       'The Hamilton',             'TXN-JS-007'),
(4, CURRENT_DATE - 12, -19.99,   'Book purchase',                   'shopping',     'Amazon.com',               'TXN-JS-008'),
(4, CURRENT_DATE - 14, -135.00,  'Phone bill',                      'utilities',    'Verizon Wireless',         'TXN-JS-009'),
(4, CURRENT_DATE - 18, -58.40,   'Grocery run',                     'groceries',    'Safeway',                  'TXN-JS-010'),
(4, CURRENT_DATE - 20, -200.00,  'Transfer to savings',             'transfer',     'Internal Transfer',        'TXN-JS-011'),
(4, CURRENT_DATE - 22, -75.00,   'Yoga studio monthly',             'health',       'CorePower Yoga',           'TXN-JS-012'),
(4, CURRENT_DATE - 25, -28.50,   'Coffee and snacks',               'dining',       'Peets Coffee',             'TXN-JS-013'),
(4, CURRENT_DATE - 28, -110.00,  'Electric bill',                   'utilities',    'Pepco Energy',             'TXN-JS-014');

-- Carlos Rivera — checking (account_id=6)
INSERT INTO transactions (account_id, transaction_date, amount, description, category, merchant, reference_number) VALUES
(6, CURRENT_DATE - 1,  -185.30,  'Business dinner',                 'dining',       'Peter Luger Steakhouse',   'TXN-CR-001'),
(6, CURRENT_DATE - 2,  -45.00,   'Taxi to office',                  'transportation','Uber',                    'TXN-CR-002'),
(6, CURRENT_DATE - 3,  8750.00,  'Bi-weekly salary deposit',        'income',       'Goldman Sachs Payroll',    'TXN-CR-003'),
(6, CURRENT_DATE - 5,  -320.00,  'Client dinner expense',           'dining',       'Nobu NYC',                 'TXN-CR-004'),
(6, CURRENT_DATE - 6,  -78.50,   'Dry cleaning pickup',             'services',     'Madame Paulette',          'TXN-CR-005'),
(6, CURRENT_DATE - 8,  -2100.00, 'Monthly parking garage',          'transportation','Icon Parking',            'TXN-CR-006'),
(6, CURRENT_DATE - 10, -167.90,  'Grocery delivery',                'groceries',    'FreshDirect',              'TXN-CR-007'),
(6, CURRENT_DATE - 12, -500.00,  'ATM cash withdrawal',             'cash',         'ATM - Citibank',          'TXN-CR-008'),
(6, CURRENT_DATE - 15, -89.00,   'Theater tickets',                 'entertainment','Broadway.com',             'TXN-CR-009'),
(6, CURRENT_DATE - 17, 8750.00,  'Bi-weekly salary deposit',        'income',       'Goldman Sachs Payroll',    'TXN-CR-010'),
(6, CURRENT_DATE - 18, -3000.00, 'Transfer to investment account',  'transfer',     'Internal Transfer',        'TXN-CR-011'),
(6, CURRENT_DATE - 20, -450.00,  'New suit purchase',               'shopping',     'Brooks Brothers',          'TXN-CR-012'),
(6, CURRENT_DATE - 22, -62.30,   'Wine delivery',                   'dining',       'Wine.com',                 'TXN-CR-013'),
(6, CURRENT_DATE - 25, -215.00,  'Con Edison electric bill',        'utilities',    'Con Edison',               'TXN-CR-014'),
(6, CURRENT_DATE - 28, -1200.00, 'Quarterly tax estimate payment',  'taxes',        'IRS EFTPS',                'TXN-CR-015');

COMMIT;
