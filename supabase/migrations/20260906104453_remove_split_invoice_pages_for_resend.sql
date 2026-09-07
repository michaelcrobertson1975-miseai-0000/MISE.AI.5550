DELETE FROM public.invoice_corrections WHERE invoice_id IN (
  '028baa5c-5035-437c-954a-f93e6a20c56a', '3e091660-680c-46b2-a4cf-6e8145e7c46d'
);
DELETE FROM public.invoice_line_items WHERE invoice_id IN (
  '028baa5c-5035-437c-954a-f93e6a20c56a', '3e091660-680c-46b2-a4cf-6e8145e7c46d'
);
DELETE FROM public.invoices WHERE id IN (
  '028baa5c-5035-437c-954a-f93e6a20c56a', '3e091660-680c-46b2-a4cf-6e8145e7c46d'
);
