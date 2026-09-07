-- MiseAI Inbound Invoice Engine — initial schema
-- Status vocabulary: 'pending' | 'completed' | 'requires_human_review'

CREATE TABLE IF NOT EXISTS invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL,
    vendor_name VARCHAR(255),
    invoice_number VARCHAR(100),
    invoice_date DATE,
    subtotal NUMERIC(10,2),
    tax NUMERIC(10,2),
    grand_total NUMERIC(10,2),
    status VARCHAR(50) DEFAULT 'pending',
    flag_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS invoice_line_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id UUID REFERENCES invoices(id) ON DELETE CASCADE,
    item_description TEXT NOT NULL,
    raw_quantity NUMERIC(10,3),
    raw_uom VARCHAR(50),
    raw_unit_price NUMERIC(10,4),
    line_total NUMERIC(10,2),
    standardized_base_unit VARCHAR(20),
    total_base_units NUMERIC(10,3),
    cost_per_base_unit NUMERIC(10,4),
    is_flagged BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS monthly_pnl_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL,
    period_year_month VARCHAR(7) NOT NULL,
    gross_sales NUMERIC(12,2) DEFAULT 0.00,
    cogs_food NUMERIC(12,2) DEFAULT 0.00,
    cogs_beverage NUMERIC(12,2) DEFAULT 0.00,
    labor_kitchen NUMERIC(12,2) DEFAULT 0.00,
    labor_management NUMERIC(12,2) DEFAULT 0.00,
    labor_front_house NUMERIC(12,2) DEFAULT 0.00,
    prime_cost_total NUMERIC(12,2) GENERATED ALWAYS AS (cogs_food + cogs_beverage + labor_kitchen + labor_management + labor_front_house) STORED,
    prime_cost_percentage NUMERIC(5,2),
    is_closed BOOLEAN DEFAULT FALSE,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS monthly_pnl_snapshots_client_period_idx
    ON monthly_pnl_snapshots (client_id, period_year_month);
CREATE INDEX IF NOT EXISTS invoices_review_queue_idx
    ON invoices (client_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS invoice_line_items_invoice_idx
    ON invoice_line_items (invoice_id);
