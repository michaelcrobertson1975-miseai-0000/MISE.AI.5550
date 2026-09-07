DELETE FROM public.invoice_corrections WHERE invoice_id IN (
  'bc103131-1bdb-4577-b6ea-75bd99f89410',
  '9f84a0e7-a6a2-4b9b-896b-1a1821a0152f',
  'cefe2c08-f36f-41c6-a64f-71e2f7929340'
);
DELETE FROM public.invoice_line_items WHERE invoice_id IN (
  'bc103131-1bdb-4577-b6ea-75bd99f89410',
  '9f84a0e7-a6a2-4b9b-896b-1a1821a0152f',
  'cefe2c08-f36f-41c6-a64f-71e2f7929340'
);
DELETE FROM public.invoices WHERE id IN (
  'bc103131-1bdb-4577-b6ea-75bd99f89410',
  '9f84a0e7-a6a2-4b9b-896b-1a1821a0152f',
  'cefe2c08-f36f-41c6-a64f-71e2f7929340'
);
