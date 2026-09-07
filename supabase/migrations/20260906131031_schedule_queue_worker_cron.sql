SELECT cron.schedule(
  'process-ingestion-queue',
  '* * * * *',
  $$
  SELECT net.http_post(
    url := 'https://qhfmywontdwwfapowqpo.supabase.co/functions/v1/process-queue',
    headers := jsonb_build_object(
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFoZm15d29udGR3d2ZhcG93cXBvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgzMjg1NTEsImV4cCI6MjEwMzkwNDU1MX0.O0JeiPQVUh2OQCTgTrVdHnkvkl2J9mGeFaLZorOJfVg',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
