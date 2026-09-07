DELETE FROM public.invoice_corrections WHERE invoice_id IN (
  '55da4d52-b4eb-4cf9-b473-c6af1872cb7c', '272c40bc-9d87-4812-852f-6eb5f15c9723'
);
DELETE FROM public.invoice_line_items WHERE invoice_id IN (
  '55da4d52-b4eb-4cf9-b473-c6af1872cb7c', '272c40bc-9d87-4812-852f-6eb5f15c9723'
);
DELETE FROM public.invoices WHERE id IN (
  '55da4d52-b4eb-4cf9-b473-c6af1872cb7c', '272c40bc-9d87-4812-852f-6eb5f15c9723'
);
