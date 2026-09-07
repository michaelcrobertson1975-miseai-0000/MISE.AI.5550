ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS api_token uuid DEFAULT gen_random_uuid();

COMMENT ON COLUMN public.clients.api_token IS 'Private per-client token required on every api function call, separate from the public restaurant id (clients.id). Never shown in the chef-app UI, only baked into that client''s own app config at onboarding.';

-- Every existing client gets a token immediately (the column default handles new ones).
UPDATE public.clients SET api_token = gen_random_uuid() WHERE api_token IS NULL;
